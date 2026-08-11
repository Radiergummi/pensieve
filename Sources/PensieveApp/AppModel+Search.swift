// Sources/PensieveApp/AppModel+Search.swift
import Foundation
import PensieveKit

extension AppModel {
  /// Index catch-up on the launch + ⌘R cadence (the sync daemon also runs both periodically).
  ///
  /// The search index backs the ONLY retrieval path, so it is ungated and run inline rather than
  /// detached: a whole rebuild is milliseconds of pure SQL with no model to load, and doing it here
  /// is what makes the search field usable the moment it accepts input on a first launch. The
  /// vector index stays best-effort, detached and toggle-gated — it loads an NL asset and embeds,
  /// which is far too slow for the UI path.
  func syncSearchIndexes() {
    guard let database else { return }
    SearchIndexer(store: searchStore).sync(database)
    searchIndexState = searchStore.state()

    if AppDefaults.semanticSearchEnabled {
      let store = semanticStore, embedder = self.embedder
      Task.detached { await SemanticIndexer(store: store, embedder: embedder).sync(database) }
    }
  }

  /// The keystroke entry point (from the .searchable field). Coalesces rapid typing into one
  /// debounced DB read; an empty/whitespace field clears immediately so exiting search stays crisp.
  func searchTextChanged() {
    guard isSearching else { runSearch(); return }   // empty → synchronous clear via runSearch's guard
    Task { await searchDebouncer.schedule() }
  }

  /// The one entry point for the actual search read (the debounced keystroke path AND the liveness
  /// refresh). Cancels the prior task; runs the read off-main; assigns results under a monotonic
  /// token so a stale keystroke can't overwrite a newer result.
  func runSearch() {
    searchTask?.cancel()
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= SearchQueries.minQueryLength, let database else {
      searchHits = []
      pinnedTopHit = nil
      semanticHits = []
      expandedLooseEndID = nil   // emptying the field (any way) exits search coherently, incl. the leaf one-home override
      return
    }
    let visible = NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)
    // Pre-Task locals: reading self off-main is an isolation violation.
    let includeArchived = (searchScope == .all)
    let rawQuery = searchText
    let scopedNodes = allNodes.filter {
      visible.contains($0.id) && $0.state.isSearchable(includeArchived: includeArchived)
    }
    // The pin is pure and instant — no DB, no index. Assign it before the async read so navigation
    // never waits on ranking.
    pinnedTopHit = SearchQueries.topHit(query: query, in: scopedNodes)
    searchIndexState = searchStore.state()

    searchToken += 1
    let token = searchToken
    let store = searchStore
    searchTask = Task { [weak self] in
      let hits = await Task.detached {
        // Fully qualified: `AppModel.SearchScope` (the UI's active/all enum) shadows the Kit type
        // of the same name inside this extension.
        SearchQueries.search(query: rawQuery,
                             scope: PensieveKit.SearchScope(visibleNodeIDs: visible,
                                                            includeArchived: includeArchived),
                             store: store, database)
      }.value
      guard let self, self.searchToken == token, !Task.isCancelled else { return }
      self.searchHits = hits

      guard AppDefaults.semanticSearchEnabled else { self.semanticHits = []; return }
      let related = await SemanticQueries.search(
        query: query,
        scope: SemanticSearchScope(visibleNodeIDs: visible, excludingIDs: Set(hits.map { $0.id }),
                                   limit: 8, floor: 0.25, includeArchived: includeArchived),
        store: self.semanticStore, embedder: self.embedder, database)
      guard self.searchToken == token, !Task.isCancelled else { return }
      self.semanticHits = related
    }
  }

  /// A node search hit: drive the detail only (the briefing-card pattern), leaving sidebarSelection
  /// so clearing the field restores a coherent middle list. Clears any pending loose-end expand.
  func selectSearchNode(_ id: UUID) {
    expandedLooseEndID = nil
    selectedNodeID = id
  }

  /// Any ranked hit. A loose end auto-expands its cited row; a node or an event drives the detail
  /// (an event's home is its node).
  func selectSearchHit(_ hit: SearchHit) {
    if hit.kind == .looseEnd {
      selectedNodeID = hit.nodeID
      expandedLooseEndID = hit.id
    } else {
      selectSearchNode(hit.nodeID)
    }
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

  /// Exit search mode (e.g. on sidebar navigation): clear the field, results, and pending expand.
  func clearSearch() {
    searchText = ""
    searchHits = []
    pinnedTopHit = nil
    semanticHits = []
    expandedLooseEndID = nil
    searchTask?.cancel()
  }
}
