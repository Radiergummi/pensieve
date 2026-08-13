// Sources/PensieveApp/AppModel.swift
import Foundation
import SwiftUI
import Observation
import SQLiteData
import GRDB
import os
import PensieveKit

@MainActor
@Observable
final class AppModel {
  var lists = SmartLists(whatsNext: [], dormant: [], recentlyActive: [])
  var forest: [NodeForestNode] = []
  var archivedForest: [NodeForestNode] = []
  var sidebarSelection: SidebarSelection? = .briefing
  var selectedNodeID: UUID?
  /// Drives the New/Edit node modal. nil = closed. Mounted in RootView.
  var editingNode: NodeEditRequest?
  /// Non-nil while a Move/Merge picker sheet is up for that node. Mounted in RootView.
  var movePickerNodeID: UUID?
  var mergePickerNodeID: UUID?
  /// Non-nil while the delete confirmation is presented for that node. Mounted in RootView.
  var pendingDeleteNodeID: UUID?
  /// The node whose open loose ends a bulk close is about to close. Drives the confirmation on
  /// `RootView`, not a dialog inside the context menu — menu content is dismissed with the menu.
  var pendingBulkCloseNodeID: UUID?
  /// The one surfaced organizing-write failure. Mounted as a single `.alert` in RootView.
  var presentedError: AppError?
  var snapshot = MonitorSnapshot(status: .notSetUp, lastCaptureAt: nil,
                                            spoolPending: 0, eventCount: 0, looseEndCount: 0)
  var briefingCards: [BriefingCard] = []
  /// Recency + open-count per node, for list rows and the detail header. Refreshed with everything
  /// else in `refresh()` rather than per view, so one batched query serves every surface. Tracked by
  /// `@Observable` on purpose — view bodies read it.
  var nodeRowFacts: [UUID: NodeRowFacts] = [:]
  /// Count of open, unlabeled, machine-suggested loose ends — the "Review Suggestions" badge.
  var reviewCount = 0
  /// Open loose ends across every visible, active node — the Loose Ends sidebar row's count.
  /// Completed deliberately has no counterpart: it grows without bound, and a number there invites
  /// reading it as a score.
  var triageCount = 0
  /// Set by the AppDelegate when an external `pensieve://` URL is opened; observed by the
  /// always-mounted menu-bar label, which applies it and clears it back to nil.
  var pendingDeepLink: DeepLink?
  /// Set by File ▸ Open in New Window (⌘⌥N); observed by RootView, which opens a recall window
  /// via its own openWindow environment and clears it. (RootView is a View, so it reliably has
  /// openWindow; a Commands struct's environment access is less reliable — hence this bridge.)
  var openNodeRequest: UUID?
  /// "Since when" the Briefing measures movement: the previous launch's timestamp (or 7 days ago on
  /// first run). Fixed for the session so cards don't shift under you while the window is open.
  let briefingSince: Date

  @ObservationIgnored var database: (any DatabaseWriter)?
  /// Persistent spool connection, reused for BOTH drains and the heartbeat. Opening a fresh
  /// connection per refresh/drain touches the store dir's `-shm`/`-wal` sidecars, which re-fires
  /// the FSEvents watch below into a busy-loop; a long-lived connection reads without that churn.
  @ObservationIgnored private var spool: CaptureSpool?
  // Tracked (NOT @ObservationIgnored): read by view bodies via node(_:) — e.g. RecallWindowView,
  // whose body reads only node(nodeID). Silencing it would leave that body with no observation
  // dependency, so a cold-restored recall window could never recover from its transient nil.
  // NOT private: AppModel+Search.swift and AppModel+Organizing.swift also read it.
  var allNodes: [Node] = []
  /// The active Focus context ("" = no Focus / unfiltered), mirrored from UserDefaults by the
  /// SetFocusFilterIntent. Drives the visible-node filter applied in refresh()/refreshGlance().
  /// NOT private: AppModel+Search.swift's runSearch() also reads it.
  @ObservationIgnored var activeFocusContext = ""
  /// Last context the forest was built for — so a context change rebuilds it even when the node set
  /// is unchanged (the `fetched != allNodes` guard alone would skip it).
  @ObservationIgnored private var lastForestContext: String?
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var spoolWatcher: DirectoryWatcher?
  @ObservationIgnored private var canonicalWatcher: DirectoryWatcher?
  @ObservationIgnored private lazy var refreshDebouncer = Debouncer(interval: 0.15) { [weak self] in
    await self?.refreshFromWatch()
  }
  @ObservationIgnored private lazy var drainDebouncer = Debouncer(interval: 0.15) { [weak self] in
    await self?.drainThenRefreshFromWatch()
  }
  /// Coalesces rapid typing in the .searchable field into one DB read (runSearch), instead of a
  /// full node+loose-end scan per keystroke.
  /// NOT private: AppModel+Search.swift's searchTextChanged() schedules it.
  @ObservationIgnored lazy var searchDebouncer = Debouncer(interval: 0.2) { [weak self] in
    await self?.runSearch()
  }
  @ObservationIgnored private var started = false
  // NOT lazy: rebuilt when the provider preference/config changes (SettingsView), so an in-session
  // switch takes effect on the next narration instead of requiring a relaunch. Bootstrapped cheaply
  // here; `init()` calls rebuildSummaryBuilder() to fold in any configured cloud provider.
  // NOT private: rebuildSummaryBuilder()/narration()/describeNode() live in AppModel+Narration.swift
  // and need to read/write it. Still module-internal — no external exposure change.
  @ObservationIgnored var summaryBuilder = SummaryBuilder(provider: ClaudeCLIProvider())
  /// The raw narration provider, retained so the manual "describe this node" action can call
  /// `NodeDescriber.describe` directly (SummaryBuilder's provider is private). Rebuilt alongside
  /// `summaryBuilder` on a provider/config change.
  @ObservationIgnored var descriptionProvider: any LLMProvider = ClaudeCLIProvider()
  /// The provider kind the current `summaryBuilder` uses — folded into the narration cache key so a
  /// provider/model switch invalidates prose cached under the old provider.
  @ObservationIgnored var providerKind = "claudeCLI"

  /// Persisted narration: prose + the invalidation key it was generated for. Keyed per DB path
  /// (NEW pattern — lastOpenedAt is a single global key today) so throwaway smoke/test stores
  /// don't pollute the real cache. Device-local: narration is a derived, provider-specific
  /// output cache and must not sync.
  struct CachedNarration: Codable { let prose: String; let key: String }
  @ObservationIgnored var narrationCache: [UUID: CachedNarration] = [:]

  /// Bumped on launch + ⌘R (drainThenRefresh). Views key their reload `.task` on it so the OPEN
  /// detail re-narrates after a refresh. The watch-driven refreshDebouncer calls `refresh()` (not
  /// drainThenRefresh), so this never bumps on background liveness updates.
  private(set) var refreshToken = 0

  /// Bumped when an on-demand translation lands. Its own signal rather than `refreshToken`, because
  /// a `refreshToken` bump means ⌘R: `DetailView` reads it as `isRefresh` and force-regenerates the
  /// narration through the LLM. Translating a loose end must repaint the pane, not re-narrate it.
  /// NOT `private(set)`: bumped from `AppModel+Translation.swift`, a different file in the same module.
  var translationRevision = 0

  /// Bumped when a loose end's status changes. Its own signal for the same reason
  /// `translationRevision` is: the feeds and the detail pane key their reload `.task` on
  /// `refreshToken`, which `refresh()` deliberately does not bump (it means ⌘R, and `DetailView`
  /// reads it as `isRefresh` and re-narrates through the LLM). Without this, a resolve wrote to the
  /// store, decremented the sidebar count, and left the resolved row sitting in the feed until the
  /// user happened to press ⌘R — caught by two independent reviews.
  var looseEndRevision = 0

  // MARK: - In-app find
  var searchText: String = ""
  /// ⌘F search scope. `.all` opts archived nodes into results. Observable → drives the scope bar.
  enum SearchScope: Hashable { case active, all }
  var searchScope: SearchScope = .active
  // All four are written by AppModel+Search.swift's runSearch()/clearSearch(), hence not private(set).
  /// The single ranked result list.
  var searchHits: [SearchHit] = []
  /// The node pinned above the list for guaranteed navigation. Selected by scanning the visible
  /// node set, NOT the capped list — see SearchQueries.topHit.
  var pinnedTopHit: SearchHit?
  /// Whether the index can answer at all — distinct from "no matches", so an unbuilt index does
  /// not read as "you never worked on that".
  var searchIndexState: SearchIndexState = .absent
  /// An index rebuild is in flight. Not observed by any view — it exists only to keep the watch-driven
  /// refresh from stacking whole-corpus rebuilds on top of each other.
  @ObservationIgnored var isSyncingIndexes = false
  /// A sync request that arrived while one was in flight. Re-run rather than dropped, because the
  /// in-flight rebuild can overwrite a targeted `updateStatus` that landed mid-flight.
  @ObservationIgnored var pendingIndexSync = false
  /// The loose-end row a search hit should auto-expand + scroll to. Consumed by LooseEndRow/DetailView.
  var expandedLooseEndID: UUID?
  /// Set by the Find command; RootView observes it to move focus into the .searchable field.
  var focusSearchRequested = false
  // NOT private: AppModel+Search.swift's runSearch()/clearSearch() also read/write these.
  @ObservationIgnored var searchTask: Task<Void, Never>?
  @ObservationIgnored var searchToken = 0
  @ObservationIgnored lazy var searchStore = SearchIndexStore(url: PensievePaths.searchIndexURL())
  /// `lazy` matters: with the translation target off, neither this store nor the translator below is
  /// ever touched, so no store file is created and no model asset loads.
  @ObservationIgnored lazy var translationStore = TranslationStore(url: PensievePaths.translationCacheURL())
  @ObservationIgnored lazy var translator: Translator? = makeDefaultTranslator()
  /// Trailing-edge: translating eight loose ends in a row must cause ONE whole-corpus rebuild, not
  /// eight. The same coalescer the liveness watches run through.
  @ObservationIgnored lazy var translationDebouncer = Debouncer(interval: 0.4) { [weak self] in
    await MainActor.run { self?.syncSearchIndexes() }
  }
  /// Shared across every window and both loose-end surfaces so a transcript is parsed once, not
  /// once per expanded row. Invalidation is per-entry file-fingerprint, inside the loader.
  @ObservationIgnored lazy var provenanceLoader: ProvenanceLoader? = {
    guard let database else { return nil }
    return ProvenanceLoader(database: database)
  }()

  /// The single source of truth for "search mode is active" — a non-empty trimmed field. Every
  /// site that branches on search (the middle content, the refresh re-run, the detail one-home
  /// override, clear-on-navigation) reads this, so the trimming rule can't drift.
  var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  private static let lastOpenedKey = "pensieve.lastOpenedAt"

  init() {
    let prev = UserDefaults.standard.object(forKey: Self.lastOpenedKey) as? Date
    briefingSince = prev ?? Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    UserDefaults.standard.set(Date(), forKey: Self.lastOpenedKey)
    rebuildSummaryBuilder()
  }

  func start() {
    guard !started else { return }
    started = true
    AppLog.app.info("App started, canonical=\(Stores.canonicalURL.path, privacy: .public) spool=\(Stores.spoolURL.path, privacy: .public)")
    // Open the canonical store read/write (needed for the launch drain). Missing store degrades to empty.
    database = try? openCanonicalDatabase(at: Stores.canonicalURL)
    loadNarrationCache()
    spool = try? CaptureSpool(at: Stores.spoolURL)   // persistent — see the property note above
    activeFocusContext = UserDefaults.standard.string(forKey: FocusFilterDefaults.activeContextKey) ?? ""
    Task { await drainThenRefresh() }

    // Liveness (retires the 3 s Timer). Watches are app-lifetime (this AppModel never deinits),
    // so the menu-bar glyph stays live even when the main window is closed.
    if let database {
      observationTask = Task { [weak self] in
        let observation = ValueObservation.tracking { database in try Event.fetchCount(database) }
        do {
          for try await _ in observation.values(in: database) {
            await self?.refreshDebouncer.schedule()   // in-process writes (own drains, future edits)
          }
        } catch { /* observation ended; watches still cover changes */ }
      }
    }
    let canonicalDir = Stores.canonicalURL.deletingLastPathComponent().path
    let spoolDir = Stores.spoolURL.deletingLastPathComponent().path
    canonicalWatcher = DirectoryWatcher(paths: [canonicalDir]) { [weak self] in
      Task { await self?.refreshDebouncer.schedule() }   // catches the EXTERNAL daemon's writes
    }
    spoolWatcher = DirectoryWatcher(paths: [spoolDir]) { [weak self] in
      Task { await self?.drainDebouncer.schedule() }      // new git/session activity → self-drain
    }

    AppLog.app.info("Liveness watchers registered")

    // The SetFocusFilterIntent runs in-process and writes UserDefaults → observe on the main queue.
    NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                           object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.focusContextDidChange() }
    }
  }

  /// On-demand equivalent of the launch drain+refresh, for the ⌘R Refresh menu command.
  func refreshNow() async { await drainThenRefresh() }

  private func drainThenRefresh() async {
    AppLog.app.info("Drain+refresh triggered")
    if let database, let spool {
      _ = try? await Ingester(spool: spool, database: database).drain()   // no LLM: spool → events only
    }
    refresh()
    // launch/⌘R: do NOT blanket-clear — cachedNarration/narration are key-aware, so unchanged
    // nodes reuse persisted prose and only changed nodes regenerate. ⌘R force-refresh of the
    // selected node happens in DetailView (force: on same-node token bump).
    refreshToken += 1
    await SpotlightIndexer.reindex(activeContext: activeFocusContext)   // launch + ⌘R
    syncSearchIndexes()   // see AppModel+Search.swift
  }

  /// Watch-triggered drain: ingest new spool rows on our own connection. The resulting canonical
  /// change trips ValueObservation + the canonical watch → refreshDebouncer. Does NOT clear the
  /// narration cache or bump refreshToken (those are launch/⌘R semantics).
  private func drainThenRefreshFromWatch() async {
    AppLog.app.debug("Spool watcher fired -> drain")
    if let database, let spool {
      _ = try? await Ingester(spool: spool, database: database).drain()
    }
  }

  /// Watch-triggered refresh: recompute state on the main actor, then reindex Spotlight. Kept as one
  /// @MainActor method so the debouncer's `await self?.refreshFromWatch()` needs no `MainActor.run`
  /// wrapper nor a nested `Task` — the nested Task captured the weak-`self` var in concurrently
  /// executing code, which is an error under the Swift 6 language mode.
  private func refreshFromWatch() async {
    AppLog.app.debug("Canonical watcher fired -> refresh")
    refresh()
    syncSearchIndexes()   // work just drained must become findable without waiting for ⌘R
    await reindexSpotlight()
  }

  private func reindexSpotlight() async { await SpotlightIndexer.reindex(activeContext: activeFocusContext) }

  /// UserDefaults changed — if the active Focus context flipped, re-filter the window + reindex.
  private func focusContextDidChange() {
    let new = UserDefaults.standard.string(forKey: FocusFilterDefaults.activeContextKey) ?? ""
    guard new != activeFocusContext else { return }
    AppLog.app.info("Focus context changed: '\(self.activeFocusContext, privacy: .public)' -> '\(new, privacy: .public)'")
    activeFocusContext = new
    refresh()
    Task { await SpotlightIndexer.reindex(activeContext: new) }
  }

  /// Filter a freshly-computed SmartLists to the ids visible under the active context.
  private func filtered(_ smartLists: SmartLists, _ visible: Set<UUID>) -> SmartLists {
    SmartLists(
      whatsNext: smartLists.whatsNext.filter { visible.contains($0.project.id) },
      dormant: smartLists.dormant.filter { visible.contains($0.project.id) },
      recentlyActive: smartLists.recentlyActive.filter { visible.contains($0.project.id) })
  }

  /// The two grouped aggregates every row-shaped surface renders from: the middle column, the detail
  /// header, and the menu-bar popover's rows. Both refresh paths need them, so both go through here.
  private func loadNodeRowFacts(_ database: any DatabaseWriter) {
    if let facts = try? NodeFactsQueries.rowFacts(database) { nodeRowFacts = facts }
  }

  /// Narrow refresh for the menu-bar glance: only what the popover shows (heartbeat + What's Next),
  /// skipping the briefing cards / forest that only the main window needs.
  func refreshGlance() {
    snapshot = MonitorSnapshot.gather(canonical: database, spool: spool)
    guard let database else { return }
    loadNodeRowFacts(database)
    guard let raw = try? SmartLists.compute(database, now: Date()) else { return }
    lists = activeFocusContext.isEmpty ? raw : filtered(raw, visibleNodeIDs())
  }

  func refresh() {
    // Heartbeat from the persistent connections (opening fresh ones here would re-fire the store-dir
    // watch into a busy-loop). Works before the database guard: nil connections degrade to a zero snapshot.
    snapshot = MonitorSnapshot.gather(canonical: database, spool: spool)
    guard let database else { return }
    let now = Date()
    let fetched = (try? ProjectQueries.all(database)) ?? allNodes
    let nodesChanged = fetched != allNodes
    if nodesChanged {
      allNodes = fetched
      pruneNarrationCache()
    }
    let visible = visibleNodeIDs()

    if let raw = try? SmartLists.compute(database, now: now) {
      lists = activeFocusContext.isEmpty ? raw : filtered(raw, visible)
    }
    if let raw = try? BriefingQueries.cards(database, since: briefingSince, now: now) {
      briefingCards = activeFocusContext.isEmpty ? raw : raw.filter { visible.contains($0.node.id) }
    }
    loadNodeRowFacts(database)
    if nodesChanged || activeFocusContext != lastForestContext {
      let source = activeFocusContext.isEmpty ? allNodes : allNodes.filter { visible.contains($0.id) }
      forest = NodeForest.build(source.filter { $0.state == .active })
      archivedForest = NodeForest.build(source.filter { $0.state == .archived })
      lastForestContext = activeFocusContext
    }
    reviewCount = (try? SalienceReviewQueries.pendingCount(database)) ?? 0
    triageCount = (try? LooseEndQueries.openCountAcrossNodes(database,
                                                             visibleNodeIDs: visible)) ?? 0
    if isSearching { runSearch() }
  }

  /// The Focus-visible node set. Extracted because five surfaces now need it (both refreshes, search
  /// and the two cross-node loose-end feeds) and an inlined copy that drifted would scope one list
  /// differently from the rest.
  func visibleNodeIDs() -> Set<UUID> {
    NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)
  }

  func node(_ id: UUID) -> Node? { allNodes.first { $0.id == id } }

  /// Count of top-level project nodes, for the content-column header.
  var projectCount: Int {
    allNodes.filter { $0.parentID == nil && $0.kind == .project && $0.state == .active }.count
  }

  /// Direct children of `id`, name-sorted (thin wrapper over the pure Kit helper).
  func children(of id: UUID) -> [Node] { NodeForest.children(of: id, in: allNodes) }

  /// Children of `id` restricted to the same "world" as `id` itself — archived children under an
  /// archived node, active children under an active one — so the two "worlds" don't bleed into
  /// each other. The ONE state-scoped children filter: `middleKind()` and `detailShowsLooseEnds`
  /// both call this so they can never disagree about whether `id` has visible children.
  func visibleChildren(of id: UUID) -> [Node] {
    let showArchived = node(id)?.state == .archived
    return children(of: id).filter { ($0.state == .archived) == showArchived }
  }

  // MARK: - What the middle column shows
  // `middleKind()`, `selectMiddleNode`, `middleTitle` and `detailShowsLooseEnds` live in
  // AppModel+Middle.swift — moved there when the loose-end feeds pushed this file past the 400-line cap.

  // MARK: - Organizing writes
  // All of them — including the two modal commits — live in AppModel+Organizing.swift, alongside the
  // shared refuse/fail/displayName/defaultKind/presentNewNode/presentEditNode helpers.
}
