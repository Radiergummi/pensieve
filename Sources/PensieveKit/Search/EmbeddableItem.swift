import Foundation
import SQLiteData

public struct EmbeddableItem: Sendable {
  public let itemID: String, kind: String, nodeID: String, state: String, text: String
  /// Newline-joined changed-file paths. Events only; "" everywhere else. Indexed into the FTS5
  /// search index's SEPARATE `document_files` table, never beside the text: FTS5 normalises `bm25()`
  /// by the row's TOTAL token count across all columns, so paths sharing a row with text would
  /// discount every commit's text matches. Measured — see the spec's verification gate.
  public let files: String
  /// "" for the original text, a BCP-47 code ("de") for a translation of it. A translation is a
  /// SEPARATE document sharing the original's `itemID`, never an extra column beside it: FTS5
  /// normalises `bm25()` by a row's TOTAL token count across all columns, so German text sharing a
  /// row with English would discount every English match. The index carries this as
  /// `language UNINDEXED`, which contributes no tokens.
  public let language: String
  /// The item's own lifecycle state, as `LooseEndStatus` raw values. Node and event rows carry
  /// `"open"`: the SQL filter then applies the allow-list uniformly instead of switching on `kind`,
  /// and a kind-conditional filter is exactly the asymmetry that lets the index and the canonical
  /// re-check drift apart.
  public let status: String
  public init(itemID: String, kind: String, nodeID: String, state: String, text: String,
              files: String = "", language: String = "",
              status: String = LooseEndStatus.open.rawValue) {
    self.itemID = itemID; self.kind = kind; self.nodeID = nodeID
    self.state = state; self.text = text; self.files = files; self.language = language
    self.status = status
  }
  /// Stable across processes/runs (String.hashValue is per-process salted — do NOT use it here).
  /// Hashes `text` ONLY. `files` is excluded so that a change to path indexing does not invalidate
  /// every item's content hash; `SearchIndexer.corpusHash` folds `files` in separately, so a
  /// paths-only change is still noticed. (Historically this split existed to avoid re-embedding on
  /// the retired vector path; the reason is now purely about what the FTS5 rebuild guard tracks.)
  public var contentHash: String {
    var hash = StableHash()
    hash.absorb(text)
    return hash.hexValue
  }
}

/// v1 producer of the search corpus: active AND archived nodes + their open loose ends +
/// their enriched events, each tagged with its owning node's state (the query layer scopes on it).
/// `muted` is never indexed. The seam future producers (transcript chunks, etc.) extend.
/// Event hygiene (spec P1): `git.checkout` events are dropped (no work content), and identical
/// event texts within a node are de-duplicated, keeping the earliest by (occurredAt, id).
public enum EmbeddableCorpus {
  /// Degenerate LLM output ("[]", "/", stray punctuation) is not searchable content — it tokenises
  /// to noise and renders as an empty-looking result row. Applies ONLY to model-generated text;
  /// human-authored text (a git commit subject) is legitimately short. Kept as a second line of
  /// defense: `SessionSummarizer` now refuses to store such output in the first place, but the
  /// store already holds historical rows written before that guard existed.
  static func isSearchable(_ text: String) -> Bool { TextQuality.isProse(text) }

  /// `translations` + `language` add a SECOND document per item whose generated text has a stored
  /// translation, sharing the original's `itemID`. Defaulted to off, so a caller that has no opinion
  /// (every test, the CLI paths that only read) produces exactly the corpus it did before.
  public static func gather(_ database: any DatabaseReader,
                            translations: TranslationStore? = nil,
                            language: String = TranslationTarget.off) throws -> [EmbeddableItem] {
    try database.read { database in
      var out: [EmbeddableItem] = []
      // A translated document, or nothing, appended directly. Off, no store, or no stored translation
      // all mean "the original is the only document for this item" — sparse translation is the
      // steady state. Appends internally (rather than returning an optional for the caller to
      // branch on) to keep `gather`'s own cyclomatic complexity down; the branch just moves here.
      //
      // `kind` is a parameter, not a constant: a translated document MUST carry the same kind as the
      // original it shadows, because `buildHits` maps `kind` to `SearchHit.Kind` and resolves the item
      // through that branch. A translated loose end tagged "node" would resolve against the Node
      // table by a loose-end id and silently vanish. Takes the loose end itself (not its id/nodeID
      // separately) to stay within SwiftLint's parameter-count limit.
      func appendTranslatedLooseEnd(_ field: TranslationField, of sourceText: String, kind: String,
                                    from looseEnd: LooseEnd, state: String) {
        guard !language.isEmpty, let translations,
              let text = translations.translation(field: field, sourceText: sourceText,
                                                  language: language)
        else { return }
        out.append(EmbeddableItem(itemID: looseEnd.id.uuidString, kind: kind,
                                  nodeID: looseEnd.nodeID.uuidString, state: state,
                                  text: text, language: language))
      }
      // Active AND archived: archiving hides work from the normal views, it does not make the work
      // unrecallable. `muted` stays out of the corpus entirely. Each item carries its owning node's
      // real state, which is what lets the query layer scope results per search scope.
      let nodes = try Node.all.fetchAll(database)
        .filter { $0.state == .active || $0.state == .archived }
      let stateByNodeID = Dictionary(nodes.map { ($0.id, $0.state.rawValue) },
                                     uniquingKeysWith: { firstState, _ in firstState })
      for node in nodes {
        out.append(.init(itemID: node.id.uuidString, kind: "node", nodeID: node.id.uuidString,
                         state: node.state.rawValue, text: [node.name, node.description].filter { !$0.isEmpty }.joined(separator: " — ")))
        appendTranslatedNodeDocument(for: node, into: &out, translations: translations, language: language)
      }
      let ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(database)
      for looseEnd in ends {
        guard let state = stateByNodeID[looseEnd.nodeID] else { continue }
        out.append(.init(itemID: looseEnd.id.uuidString, kind: "loose_end", nodeID: looseEnd.nodeID.uuidString,
                         state: state, text: [looseEnd.text, looseEnd.quote].filter { !$0.isEmpty }.joined(separator: " — ")))
        // Text ONLY — never the quote. The original document is "text — quote"; a translated
        // document that re-appended the English quote would manufacture a duplicate hit, and the
        // quote is verbatim provenance that must never be adjacent to a translation.
        appendTranslatedLooseEnd(.looseEndText, of: looseEnd.text, kind: "loose_end",
                                 from: looseEnd, state: state)
      }
      // Hygiene (spec P1). Two rules, both bounded to events:
      //  1. `git.checkout` carries no work content — 261 of 1,686 rows were bare "checkout <branch>",
      //     84 of them literally "checkout HEAD". They only ever occupied top-k slots.
      //  2. De-duplicate identical texts WITHIN a node, keeping the earliest by (occurredAt, id).
      //     Deliberately not global: collapsing "fix ci" across three projects would silently pick
      //     which project owns the only findable copy — a grounding call, not hygiene. Ordering is
      //     explicit because `Event.all` has none, so "the first occurrence" would otherwise be
      //     whatever SQLite happened to return, and could differ between rebuilds.
      let events = try Event.order { ($0.occurredAt, $0.id) }.fetchAll(database)
      var seenTextsByNode: [UUID: Set<String>] = [:]
      for event in events where event.kind != CaptureKind.gitCheckout {
        guard let state = stateByNodeID[event.nodeID] else { continue }
        let text: String?
        switch event.kind {
        // LLM-enriched prose — gate it: degenerate model output ("[]", a bare "/") is not content.
        case CaptureKind.ccSession: text = event.workSummary.flatMap { isSearchable($0) ? $0 : nil }
        // Human-authored (a git commit subject). NOT gated — "wip" and "fix ci" are real, short work.
        default: text = event.summary.isEmpty ? nil : event.summary
        }
        guard let text else { continue }
        guard seenTextsByNode[event.nodeID, default: []].insert(text).inserted else { continue }
        out.append(.init(itemID: event.id.uuidString, kind: "event", nodeID: event.nodeID.uuidString,
                         state: state, text: text, files: Self.changedFiles(in: event.detailJSON)))
      }
      return out
    }
  }

  /// A node has TWO translatable fields (`name`, `description`), unlike the single-field
  /// `appendTranslatedLooseEnd` helper `gather` uses for loose ends, so it composes them into ONE
  /// document the same way the original joins them (" — ", empties filtered) rather than reusing
  /// that helper. Appends a document when EITHER field has a translation, filling the untranslated
  /// half from the original — appends directly (rather than returning an optional for the caller to
  /// branch on) to keep `gather`'s own cyclomatic complexity down.
  private static func appendTranslatedNodeDocument(for node: Node, into items: inout [EmbeddableItem],
                                                   translations: TranslationStore?, language: String) {
    guard !language.isEmpty else { return }
    let translatedName = translations?.translation(field: .nodeName, sourceText: node.name,
                                                   language: language)
    let translatedDescription = node.description.isEmpty ? nil
      : translations?.translation(field: .nodeDescription, sourceText: node.description,
                                  language: language)
    guard translatedName != nil || translatedDescription != nil else { return }
    let text = [translatedName ?? node.name, translatedDescription ?? node.description]
      .filter { !$0.isEmpty }.joined(separator: " — ")
    items.append(EmbeddableItem(itemID: node.id.uuidString, kind: "node", nodeID: node.id.uuidString,
                                state: node.state.rawValue, text: text, language: language))
  }

  /// The ingester writes {"hash","branch","files"} for a commit, with `files` newline-joined.
  /// Anything else (a session's detail, malformed JSON, an absent key) yields "".
  static func changedFiles(in detailJSON: String) -> String {
    (try? JSONDecoder().decode(CommitDetail.self, from: Data(detailJSON.utf8)))?.files ?? ""
  }

  /// Only the one key this needs, so a detail payload that grows an unrelated field of ANY type —
  /// `"additions": 12`, a nested object — keeps decoding. Decoding the whole object as
  /// `[String: String]` would fail wholesale on the first non-string value and silently drop `files`
  /// from every commit, with nothing failing except path search itself. `Ingester` happens to emit a
  /// homogeneous string dictionary today, but nothing makes it keep doing so: `encodeJSON` is generic.
  private struct CommitDetail: Decodable { let files: String? }
}
