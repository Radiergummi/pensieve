import Foundation
import GRDB
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

/// v1 producer of the search corpus: active AND archived nodes + their loose ends, open and closed
/// (👎-labelled ones excluded) + their enriched events, each tagged with its owning node's state and
/// its own status (the query layer scopes on both).
/// `muted` is never indexed. The seam future producers (transcript chunks, etc.) extend.
/// Event hygiene (spec P1): `git.checkout` events are dropped (no work content), and identical
/// event texts within a node are de-duplicated, keeping the earliest by (occurredAt, id).
///
/// Every `kind` this producer writes comes from `SearchHit.Kind`'s raw values (passages from
/// `Passage.searchKind`), never from a literal: `SearchQueries.buildHits` parses the stored string
/// back through that same enum, so a hand-written literal that stopped matching would index fine
/// and resolve to nothing — a silently partial search rather than a compile error.
public enum EmbeddableCorpus {
  /// Degenerate LLM output ("[]", "/", stray punctuation) is not searchable content — it tokenises
  /// to noise and renders as an empty-looking result row. Applies ONLY to model-generated text;
  /// human-authored text (a git commit subject) is legitimately short. Kept as a second line of
  /// defense: `SessionSummarizer` now refuses to store such output in the first place, but the
  /// store already holds historical rows written before that guard existed.
  static func isSearchable(_ text: String) -> Bool { TextQuality.isProse(text) }

  /// The nodes the corpus covers: active AND archived. Archiving hides work from the normal views, it
  /// does not make the work unrecallable; `muted` stays out entirely.
  ///
  /// Extracted so `TranslatableCorpus` reads eligibility from HERE rather than restating it. The
  /// backfill's denominator and the corpus's lookups have to be the same set, and two copies of a
  /// filter are how they stop being.
  static func corpusNodes(_ database: Database) throws -> [Node] {
    try Node.all.fetchAll(database).filter { $0.state == .active || $0.state == .archived }
  }

  /// Open AND closed loose ends, `noise` excluded. `isOpen` conflates the two, so the predicate is
  /// spelled out: 👎 asserts the text was never a loose end, whereas a closed end was real work.
  /// Shared with `TranslatableCorpus` — see `corpusNodes`.
  static func corpusLooseEnds(_ database: Database) throws -> [LooseEnd] {
    try LooseEnd.where { $0.label.neq(LooseEndLabel.noise) }.fetchAll(database)
  }

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
      //
      // `status` is read off the loose end rather than passed in, and that is load-bearing:
      // `EmbeddableItem` defaults it to `"open"`, so a translated document for a CLOSED loose end
      // that inherited the default would pass the default-scope SQL filter and then be dropped by
      // the resolver — the page-shrinking failure, reachable only through the translation path.
      // Reading it from the same row the original document reads makes the two unable to disagree
      // about eligibility, which passing a parameter alongside `kind` would only make likely.
      func appendTranslatedLooseEnd(_ field: TranslationField, of sourceText: String, kind: String,
                                    from looseEnd: LooseEnd, state: String) {
        guard !language.isEmpty, let translations,
              let text = translations.translation(field: field, sourceText: sourceText,
                                                  language: language)
        else { return }
        out.append(EmbeddableItem(itemID: looseEnd.id.uuidString, kind: kind,
                                  nodeID: looseEnd.nodeID.uuidString, state: state,
                                  text: text, language: language,
                                  status: looseEnd.status.rawValue))
      }
      // Each item carries its owning node's real state, which is what lets the query layer scope
      // results per search scope. Which nodes are eligible, and why, is `corpusNodes` — deliberately
      // not restated here, since restating it is how two copies of a filter stop agreeing.
      let nodes = try Self.corpusNodes(database)
      let stateByNodeID = Self.statesByNodeID(nodes)
      for node in nodes {
        out.append(.init(itemID: node.id.uuidString, kind: SearchHit.Kind.node.rawValue,
                         nodeID: node.id.uuidString,
                         state: node.state.rawValue, text: [node.name, node.description].filter { !$0.isEmpty }.joined(separator: " — ")))
        appendTranslatedNodeDocument(for: node, into: &out, translations: translations, language: language)
      }
      // Each item carries its own status, which is what lets the query layer scope per search scope.
      // Which loose ends are eligible — open AND closed, `noise` excluded, and why that asymmetry is
      // deliberate — is `corpusLooseEnds`.
      let ends = try Self.corpusLooseEnds(database)
      for looseEnd in ends {
        guard let state = stateByNodeID[looseEnd.nodeID] else { continue }
        out.append(.init(itemID: looseEnd.id.uuidString, kind: SearchHit.Kind.looseEnd.rawValue,
                         nodeID: looseEnd.nodeID.uuidString,
                         state: state, text: [looseEnd.text, looseEnd.quote].filter { !$0.isEmpty }.joined(separator: " — "),
                         status: looseEnd.status.rawValue))
        // Text ONLY — never the quote. The original document is "text — quote"; a translated
        // document that re-appended the English quote would manufacture a duplicate hit, and the
        // quote is verbatim provenance that must never be adjacent to a translation.
        appendTranslatedLooseEnd(.looseEndText, of: looseEnd.text,
                                 kind: SearchHit.Kind.looseEnd.rawValue,
                                 from: looseEnd, state: state)
      }
      try Self.appendEventDocuments(database, stateByNodeID: stateByNodeID, into: &out)
      return out
    }
  }

  /// The event slice of the corpus, with the spec-P1 hygiene rules. Extracted from `gather` rather
  /// than inlined so each producer's rules stay readable (and `gather` stays inside the
  /// function-body limit); it reads the same `stateByNodeID` map, so eligibility cannot diverge.
  ///
  /// Hygiene (spec P1). Two rules, both bounded to events:
  ///  1. `git.checkout` carries no work content — 261 of 1,686 rows were bare "checkout <branch>",
  ///     84 of them literally "checkout HEAD". They only ever occupied top-k slots.
  ///  2. De-duplicate identical texts WITHIN a node, keeping the earliest by (occurredAt, id).
  ///     Deliberately not global: collapsing "fix ci" across three projects would silently pick
  ///     which project owns the only findable copy — a grounding call, not hygiene. Ordering is
  ///     explicit because `Event.all` has none, so "the first occurrence" would otherwise be
  ///     whatever SQLite happened to return, and could differ between rebuilds.
  private static func appendEventDocuments(_ database: Database, stateByNodeID: [UUID: String],
                                           into out: inout [EmbeddableItem]) throws {
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
      // Rule 2 is a TEXT rule, not an item rule. Two commits can share a message ("fix ci") and
      // touch different files; dropping the whole item meant the later commit's paths were never
      // indexed, so `files:` search could not find those files at all. A repeat is therefore still
      // emitted whenever it carries paths, with `text: ""` — so `documents` holds one row per
      // distinct text (the crowding rule 2 exists to prevent) while `document_files` holds one row
      // per event (correct per-commit path attribution). `SearchIndexStore.rebuild` skips an empty
      // text the same way it already skips empty files.
      //
      // The one thing a text-less repeat cannot satisfy is `.textRestrictedByPath`, which JOINs the
      // two tables on `item_id`: "this text AND that path" still resolves through the FIRST
      // occurrence only. That is a strictly smaller gap than the paths being absent outright.
      let files = Self.changedFiles(in: event.detailJSON)
      let isFirstOccurrence = seenTextsByNode[event.nodeID, default: []].insert(text).inserted
      guard isFirstOccurrence || !files.isEmpty else { continue }
      out.append(.init(itemID: event.id.uuidString, kind: SearchHit.Kind.event.rawValue,
                       nodeID: event.nodeID.uuidString, state: state,
                       text: isFirstOccurrence ? text : "", files: files))
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
    items.append(EmbeddableItem(itemID: node.id.uuidString, kind: SearchHit.Kind.node.rawValue,
                                nodeID: node.id.uuidString,
                                state: node.state.rawValue, text: text, language: language))
  }

  /// The passage corpus, gathered from the CANONICAL `passages` table — not from transcripts. That
  /// is the simplification storing text in canonical buys: the 2026-07-19 design needed a producer
  /// with its own reconciliation path precisely because passages came from a different source than
  /// everything else. They no longer do, so pruning is membership-driven for free.
  ///
  /// Separate from `gather` rather than a `kind == "passage"` branch inside it, because the passage
  /// table rebuilds on its own hash: one mixed array would have to be partitioned and two hashes
  /// reconciled inside `rebuild`, which is the kind-conditional shape `statusFilter`'s own comment
  /// warns about.
  public static func gatherPassages(_ database: any DatabaseReader) throws -> [EmbeddableItem] {
    try database.read { database in
      let stateByNodeID = Self.statesByNodeID(try Self.corpusNodes(database))
      // Ordered so the corpus hash cannot depend on SQLite's arbitrary return order — the same
      // reason `gather` orders events explicitly.
      let passages = try Passage.order { ($0.occurredAt, $0.id) }.fetchAll(database)
      return passages.compactMap { passage in
        guard let state = stateByNodeID[passage.nodeID] else { return nil }
        return EmbeddableItem(itemID: passage.id.uuidString, kind: Passage.searchKind,
                              nodeID: passage.nodeID.uuidString, state: state,
                              text: passage.text)
      }
    }
  }

  /// Each eligible node's own state, which is what every item carries so the query layer can scope
  /// results per search scope — and, by lookup failure, what excludes items owned by a node
  /// `corpusNodes` rejected.
  private static func statesByNodeID(_ nodes: [Node]) -> [UUID: String] {
    Dictionary(nodes.map { ($0.id, $0.state.rawValue) },
               uniquingKeysWith: { firstState, _ in firstState })
  }

  /// A digest of the passage corpus that reads NO passage text — the rebuild guard, split from the
  /// gather it used to be computed from.
  ///
  /// Guarding on `corpusHash(gatherPassages(…))` cost more than the rebuild it existed to avoid:
  /// measured on the real store (31,346 passages / ~15 MB of text), the unchanged-corpus path was
  /// 0.60 s (0.21 gather + 0.42 hash) against 0.36 s to simply rebuild — and it runs on launch, ⌘R,
  /// every debounced watch refresh and every 300 s daemon cycle. The gather's own hash is a faithful
  /// digest of what the table holds; it is just far more work than deciding whether it MOVED.
  ///
  /// This reads the three columns that can change what the index rows say — the passage's id, its
  /// node, and that node's state — and skips `text`, which is the expensive 15 MB and the whole
  /// 0.42 s. Skipping it is sound because **a passage's text never changes under a fixed id**:
  /// `Ingester.replacePassages` is the only writer and it deletes the event's rows and inserts
  /// freshly-minted `Passage(id: UUID())`, so edited text always arrives as new ids. The repoint
  /// sites (`Ingester.attributeToNode`, `ProjectResolver.group`) update `nodeID` and nothing else,
  /// and archiving changes `Node.state` — both of which ARE read here.
  ///
  /// If a future writer ever UPDATEs `passages.text` in place, this guard stops noticing and the
  /// index silently keeps the old prose. `passageFingerprintTracksAReplacedPassage` pins the rule
  /// by running the supported path; a new in-place writer must fold text back in, or mint a new id.
  public static func passageCorpusFingerprint(_ database: any DatabaseReader) throws -> String {
    try database.read { database in
      let stateByNodeID = Self.statesByNodeID(try Self.corpusNodes(database))
      // Ordered by id so the digest cannot depend on SQLite's arbitrary return order, and sorted by
      // the same key the rows are keyed on, so no post-sort is needed the way `corpusHash` needs one.
      let rows = try Passage.select { ($0.id, $0.nodeID) }.order { $0.id }.fetchAll(database)
      var hash = StableHash()
      for (id, nodeID) in rows {
        // Same membership rule the producer applies, so a passage the corpus excludes cannot move
        // the fingerprint and force a rebuild that would change nothing.
        guard let state = stateByNodeID[nodeID] else { continue }
        hash.absorbField(id.uuidString)
        hash.absorbField(nodeID.uuidString)
        hash.absorbField(state)
      }
      return hash.hexValue
    }
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
