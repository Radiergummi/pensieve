// Sources/PensieveApp/AppModel+Search.swift
import Foundation
import PensieveKit

extension AppModel {
  /// The keystroke entry point (from the .searchable field). Coalesces rapid typing into one
  /// debounced DB read; an empty/whitespace field clears immediately so exiting search stays crisp.
  func searchTextChanged() {
    guard isSearching else { runSearch(); return }   // empty → synchronous clear via runSearch's guard
    Task { await searchDebouncer.schedule() }
  }

  /// The one entry point for the actual search read (the debounced keystroke path AND the liveness
  /// refresh). Cancels the prior task; runs the read off-main; assigns results under a monotonic token
  /// so a stale keystroke can't overwrite a newer result. Below the min length → clears results.
  func runSearch() {
    searchTask?.cancel()
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= SearchQueries.minQueryLength, let database else {
      searchResults = SearchResults()
      semanticHits = []
      expandedLooseEndID = nil   // emptying the field (any way) exits search coherently, incl. the leaf one-home override
      return
    }
    let visible = NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)
    let includeArchived = (searchScope == .all)   // pre-Task local: reading self.searchScope off-main is an isolation violation
    searchToken += 1
    let token = searchToken
    searchTask = Task { [weak self] in
      let results = try? await Task.detached {
        try SearchQueries.search(query: query, visibleNodeIDs: visible,
                                 includeArchived: includeArchived, database)
      }.value
      guard let self, self.searchToken == token, !Task.isCancelled else { return }
      self.searchResults = results ?? SearchResults()

      guard AppDefaults.semanticSearchEnabled else { self.semanticHits = []; return }
      let exact = Set((results?.nodes.map { $0.id } ?? []) + (results?.looseEnds.map { $0.id } ?? []))
      let sem = await SemanticQueries.search(
        query: query,
        scope: SemanticSearchScope(visibleNodeIDs: visible, excludingIDs: exact, limit: 8, floor: 0.25,
                                   includeArchived: includeArchived),
        store: self.semanticStore, embedder: self.embedder, database)
      guard self.searchToken == token, !Task.isCancelled else { return }
      self.semanticHits = sem
    }
  }

  /// A node search hit: drive the detail only (the briefing-card pattern), leaving sidebarSelection
  /// so clearing the field restores a coherent middle list. Clears any pending loose-end expand.
  func selectSearchNode(_ id: UUID) {
    expandedLooseEndID = nil
    selectedNodeID = id
  }

  /// A loose-end search hit: select its node and mark the row to auto-expand + scroll to.
  func selectSearchLooseEnd(_ hit: LooseEndHit) {
    selectedNodeID = hit.nodeID
    expandedLooseEndID = hit.id
  }

  /// A Spotlight/App-Intent loose-end open: resolve the loose end → its node (read-only lookup),
  /// select the node, and mark the row to auto-expand. Degrades honestly: a deleted loose end (no
  /// resolution) falls back to the briefing. A since-closed end still resolves → opens its node
  /// (the closed row simply won't render). Window fronting is done by `applyDeepLink`.
  func openLooseEnd(_ id: UUID) {
    guard let database,
          let facts = try? LooseEndFactsQueries.facts(for: [id], database),
          let firstFact = facts.first else {
      sidebarSelection = .briefing
      selectedNodeID = nil
      expandedLooseEndID = nil
      return
    }
    sidebarSelection = .node(firstFact.nodeID)
    selectedNodeID = firstFact.nodeID
    expandedLooseEndID = firstFact.looseEndID
  }

  /// A "Related" (semantic) search hit: a loose-end hit auto-expands like an exact loose-end hit;
  /// node/event hits drive the detail like an exact node hit (an event's home is its node).
  func selectSemanticHit(_ hit: SemanticHit) {
    if hit.kind == "loose_end" {
      selectedNodeID = hit.nodeID
      expandedLooseEndID = hit.id
    } else {
      selectSearchNode(hit.nodeID)
    }
  }

  /// Exit search mode (e.g. on sidebar navigation): clear the field, results, and pending expand.
  func clearSearch() {
    searchText = ""
    searchResults = SearchResults()
    semanticHits = []
    expandedLooseEndID = nil
    searchTask?.cancel()
  }
}
