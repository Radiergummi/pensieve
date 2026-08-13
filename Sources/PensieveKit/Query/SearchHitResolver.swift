// Sources/PensieveKit/Query/SearchHitResolver.swift
import Foundation
import SQLiteData
import GRDB

extension NodeState {
  /// The node states a search may surface: `active` always, `archived` only when the caller opted
  /// in. An allow-list, never a deny-list — `muted` is excluded in both modes, and a future state
  /// can never leak in by omission.
  ///
  /// The single source for this rule. It is applied twice per query on purpose — once in SQL so the
  /// index returns only eligible rows, once again here when each candidate is re-resolved against
  /// canonical — and those two applications MUST agree, or rows pass the query and are then silently
  /// dropped. Sharing one definition is what makes them agree.
  public static func searchable(includeArchived: Bool) -> [NodeState] {
    includeArchived ? [.active, .archived] : [.active]
  }

  public func isSearchable(includeArchived: Bool) -> Bool {
    Self.searchable(includeArchived: includeArchived).contains(self)
  }
}

/// Turns one index row into a grounded `SearchHit` by re-reading the item from the canonical store —
/// the last line of grounding defense, so a between-sync stale index row can never surface a dead
/// hit. Shared by both retrieval engines: BM25 and the vector index differ only in how they pick
/// candidates and how they highlight them, never in what a hit is allowed to be.
///
/// Takes an open `Database` rather than a `DatabaseReader` so the caller can resolve a whole
/// candidate page inside ONE read transaction instead of one per hit.
///
/// The two per-query knobs are properties rather than per-candidate arguments: they are fixed for a
/// whole result page, so the caller builds one resolver and walks its candidates with it.
struct SearchHitResolver {
  let includeArchived: Bool
  /// Widens the loose-end re-check to closed ends. A SEPARATE knob from `includeArchived` because
  /// the two dimensions are orthogonal — a hit can be an archived node's open end or an active
  /// node's closed one — even though the app's scope bar happens to drive both from one control.
  var includeClosed: Bool = false
  /// Receives the body text this hit displays and returns its snippet — the one place the two
  /// engines diverge (BM25 highlights the query's unstemmed terms, the vector index the raw query
  /// string).
  let highlight: (String) -> Snippet
  /// A stored translation of one generated field, or nil. Present so a match found ONLY in a
  /// translated document still highlights: this resolver re-reads canonical, which holds English, and
  /// `snippet(preferring:)` returns the first candidate that actually contains the query — so without
  /// the translated body in that list a German hit renders with no visible reason for being there.
  var translations: (TranslationField, String) -> String? = { _, _ in nil }

  func resolve(kind: SearchHit.Kind, itemID: UUID, score: Double,
               _ database: Database) throws -> SearchHit? {
    func eligible(_ node: Node) -> Bool { node.state.isSearchable(includeArchived: includeArchived) }

    switch kind {
    case .node:
      guard let node = try Node.where({ $0.id.eq(itemID) }).fetchOne(database),
            eligible(node) else { return nil }
      return SearchHit(id: node.id, kind: .node, nodeID: node.id, nodeName: node.name,
                       title: node.name,
                       snippet: snippet(preferring: [node.description, node.name,
                                                     translations(.nodeDescription, node.description) ?? "",
                                                     translations(.nodeName, node.name) ?? ""]),
                       score: score, isArchived: node.state == .archived)
    case .looseEnd:
      // Fetched WITHOUT a status predicate, then filtered through the shared allow-list — the same
      // rule the SQL filter renders. A hardcoded `isOpen` here is what made this the one place the
      // two could disagree. The `label != noise` half of `isOpen` is kept unconditionally: a 👎 item
      // is not in the corpus at all, so surfacing one would mean the index is stale.
      guard let looseEnd = try LooseEnd.where({ $0.id.eq(itemID) }).fetchOne(database),
            looseEnd.label != LooseEndLabel.noise,
            looseEnd.status.isSearchable(includeClosed: includeClosed),
            let node = try Node.where({ $0.id.eq(looseEnd.nodeID) }).fetchOne(database),
            eligible(node) else { return nil }
      return SearchHit(id: looseEnd.id, kind: .looseEnd, nodeID: looseEnd.nodeID,
                       nodeName: node.name, title: looseEnd.text,
                       snippet: snippet(preferring: [looseEnd.text, looseEnd.quote,
                                                     translations(.looseEndText, looseEnd.text) ?? ""]),
                       score: score, isArchived: node.state == .archived,
                       status: looseEnd.status)
    case .event:
      guard let event = try Event.where({ $0.id.eq(itemID) }).fetchOne(database),
            let node = try Node.where({ $0.id.eq(event.nodeID) }).fetchOne(database),
            eligible(node) else { return nil }
      // COUPLED to `EmbeddableCorpus.gather`, which indexes exactly ONE text per event: the
      // `workSummary` for a `cc.session` (salience-gated), the `summary` otherwise. This picks the
      // displayed text by emptiness instead, which agrees today only because extraction never sets
      // `workSummary` on a git commit. Both bodies are offered to the highlighter so the two rules
      // diverging cannot cost the row its highlight — but if they diverge on WHICH text is shown,
      // fix it here rather than papering over it.
      let workSummary = event.workSummary ?? ""
      let body = workSummary.isEmpty ? event.summary : workSummary
      return SearchHit(id: event.id, kind: .event, nodeID: event.nodeID, nodeName: node.name,
                       title: body,
                       snippet: snippet(preferring: [body, event.summary]),
                       score: score, isArchived: node.state == .archived)
    }
  }

  /// The snippet for the first candidate body that actually contains the query, falling back to the
  /// first non-empty candidate.
  ///
  /// Load-bearing because the index concatenates the fields it searches — a loose end is indexed as
  /// `text — quote`, a node as `name — description` — so a hit can legitimately match in a field the
  /// row does not lead with. Highlighting only one field then produced a correct hit with NO visible
  /// reason for being in the results, which is what the substring matcher this replaced avoided by
  /// tracking a matched field. Worst on loose ends, where the snippet is the row's entire content.
  private func snippet(preferring candidates: [String]) -> Snippet {
    for candidate in candidates where !candidate.isEmpty {
      let snippet = highlight(candidate)
      if !snippet.match.isEmpty { return snippet }
    }
    return highlight(candidates.first { !$0.isEmpty } ?? "")
  }
}
