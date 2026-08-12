// Sources/PensieveApp/AppModel+Search.swift
import Foundation
import PensieveKit

extension AppModel {
  /// Index catch-up. Runs on launch + ⌘R **and** on every watch-driven refresh — the search index
  /// backs the only retrieval path, so anything the app just drained has to become findable without
  /// waiting for ⌘R or the 300 s agent, which the user may not even have approved.
  ///
  /// Detached, despite being "just SQL": `gather` reads every node, loose end and event (decoding a
  /// JSON blob per event) and the rebuild re-tokenizes the whole corpus, which grows with the corpus
  /// and is the one full-store read that would otherwise sit on the main actor. The store also has a
  /// 5 s busy timeout because the daemon writes the same file, so a rebuild racing the agent could
  /// block the main thread for seconds — exactly when overlap is likeliest. The index is
  /// hash-guarded, so an unchanged corpus costs one gather and one hash.
  ///
  /// The state assignment and the search re-run hop back to the main actor afterwards, so a search
  /// typed before the rebuild lands is re-run against the finished index rather than the stale one.
  func syncSearchIndexes() {
    guard let database else { return }
    // One rebuild at a time. Now that this runs on every watch refresh rather than only launch/⌘R,
    // overlapping runs are otherwise possible — and `SearchIndexer` treats a `.building` flag as a
    // reason to rebuild, so a run that observed another's in-flight window would rebuild redundantly.
    // Correct either way (a rebuild is one transaction and GRDB serializes writes); this is about not
    // re-doing whole-corpus work the hash guard exists to avoid.
    guard !isSyncingIndexes else { return }
    isSyncingIndexes = true
    let searchStore = self.searchStore
    Task.detached { [weak self] in
      // `.production()`, NOT `SearchIndexer(store: searchStore)`: the defaulted initializer resolves
      // to `translations: nil, language: .off`, so this rebuild would carry no German rows while the
      // daemon's own `.production()` rebuild (Sync.swift / PensieveSyncAgent.swift) carries them —
      // each side's rebuild would then look like a corpus change to the other and undo it, forever.
      // `.production()` re-reads the target on every call (a Settings change lands without relaunch)
      // and already skips opening the translation store when the target is off.
      SearchIndexer.production().sync(database)
      // Read the state HERE, off the main actor: it is a SQL read against the pool whose 5 s busy
      // timeout is the whole reason this work is detached.
      let state = searchStore.state()
      await MainActor.run { self?.searchIndexesDidSync(state: state) }
    }
  }

  /// Back on the main actor with a rebuilt index: publish its state, and re-rank whatever the user
  /// has already typed so results never reflect an index that has since changed underneath them.
  private func searchIndexesDidSync(state: SearchIndexState) {
    isSyncingIndexes = false
    searchIndexState = state
    if isSearching { runSearch() }
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
    expandedLooseEndID = nil
    searchTask?.cancel()
  }
}
