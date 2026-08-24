// Sources/PensieveApp/AppModel+Search.swift
import Foundation
import PensieveKit

extension AppModel {
  /// The single source of truth for "search mode is active" — a non-empty trimmed field. Every
  /// site that branches on search (the middle content, the refresh re-run, the detail one-home
  /// override, clear-on-navigation) reads this, so the trimming rule can't drift.
  var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
    // A coalesced request is RE-RUN, not dropped. Dropping it left a real hole: a resolve landing
    // during an in-flight rebuild has its targeted `updateStatus` overwritten by that rebuild's
    // DELETE-and-reinsert (which gathered the corpus before the write), and its own watch event was
    // then swallowed here — leaving the index disagreeing with canonical until ⌘R or relaunch. In the
    // reopen direction that means live work stays unfindable in ⌥⌘F's default scope.
    guard !isSyncingIndexes else { pendingIndexSync = true; return }
    isSyncingIndexes = true
    let searchStore = self.searchStore
    // `.production()` is deliberately NOT used here, even though it is what the daemon and the CLI
    // call: it CONSTRUCTS a `SearchIndexStore` (and, with a language set, a `TranslationStore`), and
    // `SearchIndexStore.init` runs a `pool.write` schema check. This method runs on every
    // watch-driven refresh, so that was a write into the very directory `canonicalWatcher` watches
    // — re-firing the watch into the busy-loop `MonitorSnapshot.gather(canonical:spool:)` documents
    // and `AppModel` holds `spool`/`database` open to avoid. The model's own long-lived stores do
    // the same work with no file churn.
    //
    // `.production()`'s language rule is reproduced EXACTLY rather than defaulted away: the
    // defaulted initializer resolves to `translations: nil, language: .off`, so this rebuild would
    // carry no German rows while the daemon's own `.production()` rebuild carries them — each
    // side's rebuild would then look like a corpus change to the other and undo it, forever.
    // Resolved here, on the main actor, and re-read on every call so a Settings change lands
    // without a relaunch. Off means off: `translationStore` is `lazy`, so with no target it is
    // never touched and no file is created.
    let language = TranslationTarget.resolved()
    let translations = language.isEmpty ? nil : translationStore
    Task.detached { [weak self] in
      let indexer = SearchIndexer(store: searchStore, translations: translations, language: language)
      indexer.sync(database)
      indexer.syncPassages(database)
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
    // Exactly one catch-up run, whatever the number of requests coalesced into the flag: the guard
    // re-latches it if yet another arrives, so this cannot spin.
    if pendingIndexSync {
      pendingIndexSync = false
      syncSearchIndexes()
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
    guard query.count >= SearchQueries.minQueryLength, let database else { clearResults(); return }
    let visible = visibleNodeIDs()
    // Pre-Task locals: reading self off-main is an isolation violation.
    // One control, two dimensions. The kernel keeps `includeArchived` and `includeClosed` separate
    // because they are orthogonal — an archived node's open end and an active node's closed end are
    // different things — but the UI offers one widening, so both are driven from it.
    let includeArchived = (searchScope == .all)
    let includeClosed = (searchScope == .all)
    let rawQuery = searchText
    let scopedNodes = allNodes.filter {
      visible.contains($0.id) && $0.state.isSearchable(includeArchived: includeArchived)
    }
    // The pin is pure and instant — no DB, no index. Assign it before the async read so navigation
    // never waits on ranking.
    pinnedTopHit = SearchQueries.topHit(query: query, in: scopedNodes)

    searchToken += 1
    let token = searchToken
    let store = searchStore
    // Fully qualified: `AppModel.SearchScope` (the UI's active/all enum) shadows the Kit type of the
    // same name inside this extension. Snapshotted once, before the Task, so the ranked search and
    // the passage search (below) cannot see two different scopes if the user changes it mid-flight.
    let scope = PensieveKit.SearchScope(visibleNodeIDs: visible, includeArchived: includeArchived,
                                       includeClosed: includeClosed)
    // Pre-Task locals, read here on the main actor rather than inside the detached closure below.
    // Off means off: `translationStore`/`translator` are `lazy` and constructing either would open
    // a file/load a model, so they're touched only when a target is actually resolved.
    let language = TranslationTarget.resolved()
    let translations = language.isEmpty ? nil : translationStore
    let translator = language.isEmpty ? nil : self.translator
    searchTask = Task { [weak self] in
      let rankedHandle = Task.detached { () -> ([SearchHit], SearchIndexState)? in
        // Both detached bodies check cancellation on entry, and the outer task forwards its own
        // cancellation to them below. Neither happened before: `Task.detached` inherits nothing, so
        // `searchTask?.cancel()` cancelled the awaiting shell while up to four whole-corpus reads
        // stayed in flight against a serialized pool — the exact hazard `AppModel+Translation`
        // documents for its own detached backfill.
        guard !Task.isCancelled else { return nil }
        let hits = await SearchQueries.searchTranslatingOnEmpty(
          query: rawQuery, scope: scope, store: store, translations: translations,
          language: language, translator: translator, database)
        // The index state is read HERE, off the main actor, for the same reason the rebuild is
        // detached: it is a SQL read against a pool with a 5 s busy timeout that the daemon also
        // writes. On the main actor it was one such read per search — this file's own policy note
        // above says not to do that.
        return (hits, store.state())
      }
      // Same scope, same query, separate list — passage BM25 scores are not comparable to the
      // ranked list's, so they are appended as their own section rather than merged. A second
      // detached task, so both run concurrently rather than the passage read blocking behind the
      // ranked one — and it takes the SAME English-retry wrapper, because transcripts are
      // overwhelmingly English even when what you typed is not.
      let passagesHandle = Task.detached { () -> [PassageHit]? in
        guard !Task.isCancelled else { return nil }
        return await PassageQueries.searchTranslatingOnEmpty(
          query: rawQuery, scope: scope, store: store, language: language, translator: translator,
          database)
      }
      let results = await withTaskCancellationHandler {
        let rankedResult = await rankedHandle.value
        let passagesResult = await passagesHandle.value
        return (rankedResult, passagesResult)
      } onCancel: {
        rankedHandle.cancel()
        passagesHandle.cancel()
      }
      guard let self, self.searchToken == token, !Task.isCancelled,
            let (hits, state) = results.0, let passages = results.1 else { return }
      self.searchHits = hits
      self.passageHits = passages
      self.searchIndexState = state
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

  /// A conversation-passage hit: like a node hit, drive the detail only. There is no cited row to
  /// auto-expand — opening the transcript window in place is out of scope for this section.
  func openPassage(_ hit: PassageHit) {
    selectSearchNode(hit.nodeID)
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

  /// Everything a search produced, cleared together. One definition, shared by the too-short-query
  /// guard in `runSearch` and by `clearSearch` — they had the same four assignments written twice.
  private func clearResults() {
    searchHits = []
    passageHits = []
    pinnedTopHit = nil
    // Emptying the field (any way) exits search coherently, including the leaf one-home override.
    expandedLooseEndID = nil
  }

  /// Exit search mode (e.g. on sidebar navigation): clear the field, results, and pending expand.
  func clearSearch() {
    searchText = ""
    clearResults()
    searchTask?.cancel()
  }
}
