// Sources/PensieveApp/AppModel.swift
import Foundation
import SwiftUI
import Observation
import SQLiteData
import GRDB
import os
import PensieveKit
import WidgetKit

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
  /// The Briefing's two buckets. Partitioned once, where the cards are loaded, rather than in
  /// `BriefingView.body` — a `body` re-runs on every observation change, while the partition can only
  /// change when the cards do. (The rule itself belongs in PensieveKit beside `BriefingQueries`; it is
  /// here because the app cannot edit Kit in this pass.)
  var briefingMoved: [BriefingCard] = []
  var briefingQuiet: [BriefingCard] = []
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
  /// NOT private: `AppModel+Lifecycle.swift` opens it and both drains read it.
  @ObservationIgnored var spool: CaptureSpool?
  // Tracked (NOT @ObservationIgnored): read by view bodies via node(_:) — e.g. RecallWindowView,
  // whose body reads only node(nodeID). Silencing it would leave that body with no observation
  // dependency, so a cold-restored recall window could never recover from its transient nil.
  // NOT private: AppModel+Search.swift and AppModel+Organizing.swift also read it.
  // `private(set)`: `setAllNodes` is the only writer, so `nodesByID` cannot fall out of step.
  private(set) var allNodes: [Node] = []
  /// `allNodes` keyed by id, maintained beside it — see `setAllNodes`. Tracked for the same reason
  /// `allNodes` is: view bodies reach it through `node(_:)` and need the observation dependency.
  private(set) var nodesByID: [UUID: Node] = [:]
  /// The active Focus context ("" = no Focus / unfiltered), mirrored from UserDefaults by the
  /// SetFocusFilterIntent. Drives the visible-node filter in refresh()/refreshGlance(). Tracked, NOT
  /// @ObservationIgnored: FocusFilterBanner renders it. NOT private: runSearch() also reads it.
  var activeFocusContext = ""
  /// Last context the forest was built for — so a context change rebuilds it even when the node set
  /// is unchanged (the `fetched != allNodes` guard alone would skip it).
  @ObservationIgnored private var lastForestContext: String?
  // The five below are written only by `start()`, which lives in `AppModel+Lifecycle.swift` — hence
  // internal rather than private. Nothing outside this type touches them.
  @ObservationIgnored var observationTask: Task<Void, Never>?
  @ObservationIgnored var spoolWatcher: DirectoryWatcher?
  @ObservationIgnored var canonicalWatcher: DirectoryWatcher?
  @ObservationIgnored var translationActivityScheduler: TranslationActivityScheduler?
  @ObservationIgnored lazy var refreshDebouncer = Debouncer(interval: 0.15) { [weak self] in
    await self?.refreshFromWatch()
  }
  @ObservationIgnored lazy var drainDebouncer = Debouncer(interval: 0.15) { [weak self] in
    await self?.drainThenRefreshFromWatch()
  }
  /// Coalesces rapid typing in the .searchable field into one DB read (runSearch), instead of a
  /// full node+loose-end scan per keystroke.
  /// NOT private: AppModel+Search.swift's searchTextChanged() schedules it.
  @ObservationIgnored lazy var searchDebouncer = Debouncer(interval: 0.2) { [weak self] in
    await self?.runSearch()
  }
  @ObservationIgnored var started = false   // set by start(), in AppModel+Lifecycle.swift
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
  /// NOT `private(set)`: bumped by `drainThenRefresh()`, which lives in `AppModel+Lifecycle.swift`.
  var refreshToken = 0

  /// A user-triggered drain+refresh is in flight. Tracked (not `@ObservationIgnored`) — the menu-bar
  /// popover's heartbeat orb reads it to show a spinner. Set only by `refreshNow()`, so the
  /// background liveness watches never spin it.
  /// NOT `private(set)`: set only by `refreshNow()`, which lives in `AppModel+Lifecycle.swift`.
  var isRefreshing = false

  /// Bumped when an on-demand translation lands. Its own signal rather than `refreshToken`, because
  /// a `refreshToken` bump means ⌘R: `DetailView` reads it as `isRefresh` and force-regenerates the
  /// narration through the LLM. Translating a loose end must repaint the pane, not re-narrate it.
  /// NOT `private(set)`: bumped from `AppModel+Translation.swift`, a different file in the same module.
  var translationRevision = 0

  /// Memo behind `displayed(field:sourceText:)`. Without it every row that renders a translatable
  /// field pays one SQLite read plus a `StableHash` of the source text — per row, per body
  /// evaluation, and five times over the loose-end set on every detail load. Self-invalidating on
  /// `translationRevision`, which is the one signal meaning "a translation landed" (bumped by
  /// `translate` and by a backfill that wrote), so an entry can never outlive a write that changes
  /// its answer. Keyed by language too, so a target switch simply misses rather than needing a
  /// second invalidation rule.
  @ObservationIgnored var displayedTranslations: [DisplayedTranslationKey: String] = [:]
  @ObservationIgnored var displayedTranslationsRevision = 0

  /// Coverage as last measured, or nil when the target is off / not yet measured. Measured on demand
  /// from Settings, not on launch: it is 1,294 store reads today and nothing outside Settings shows it.
  /// It carries the language it was measured for — see `TranslationCoverage.language`.
  var translationCoverage: TranslationCoverage?
  /// Guards `translationCoverage` against a stale write from a superseded measurement, exactly as
  /// `searchToken` guards `searchHits` — see `measureTranslationCoverage` for why it is required.
  @ObservationIgnored var translationCoverageToken = 0

  /// The one slot a bulk translation occupies, manual or automatic. The type and the reasoning behind
  /// it live with the code that builds it, in `AppModel+Translation.swift`.
  var translationBackfillRun: TranslationBackfillRun?

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
  // All five are written by AppModel+Search.swift's runSearch()/clearSearch(), hence not private(set).
  /// The single ranked result list.
  var searchHits: [SearchHit] = []
  /// Conversation-passage hits, rendered as their own "From your conversations" section below the
  /// ranked list — a different FTS5 table with a different average document length, so its BM25
  /// scores are not comparable to `searchHits`' and must never be interleaved with them.
  var passageHits: [PassageHit] = []
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

  private static let lastOpenedKey = "pensieve.lastOpenedAt"

  init() {
    let prev = UserDefaults.standard.object(forKey: Self.lastOpenedKey) as? Date
    briefingSince = prev ?? Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    UserDefaults.standard.set(Date(), forKey: Self.lastOpenedKey)
    rebuildSummaryBuilder()
  }

  /// The ONE writer of `allNodes` and its `nodesByID` index, so the two cannot disagree — the drift
  /// hazard this project keeps paying for. The index exists because `node(_:)` was a linear scan of
  /// 306 nodes called once per row by three list surfaces and by every search result.
  private func setAllNodes(_ nodes: [Node]) {
    allNodes = nodes
    nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// Filter a freshly-computed SmartLists to the ids visible under the active context.
  private func filtered(_ smartLists: SmartLists, _ visible: Set<UUID>) -> SmartLists {
    SmartLists(
      whatsNext: smartLists.whatsNext.filter { visible.contains($0.project.id) },
      dormant: smartLists.dormant.filter { visible.contains($0.project.id) },
      recentlyActive: smartLists.recentlyActive.filter { visible.contains($0.project.id) })
  }

  /// The two grouped aggregates every row-shaped surface in the MAIN WINDOW renders from: the middle
  /// column, the detail header, the merge-picker's enablement, and `AppModel+Recall`.
  ///
  /// Written only by `refresh()`, not by `refreshGlance()` — the menu-bar popover used to be the fifth
  /// consumer and now renders from `NextItem.lastActivityAt` instead, which the ranking query already
  /// had. Anything added to the popover that reaches for `nodeRowFacts` will read a map the glance
  /// path never refreshes; take the facts from the item, or call this.
  private func loadNodeRowFacts(_ database: any DatabaseWriter) {
    if let facts = try? NodeFactsQueries.rowFacts(database) { nodeRowFacts = facts }
  }

  /// The Briefing's cards, Focus-scoped and partitioned into its two buckets in one place. Called by
  /// `refresh()` while Briefing is the selection, and by RootView when the user arrives on it.
  func loadBriefingCards() {
    guard let database,
          let raw = try? BriefingQueries.cards(database, since: briefingSince, now: Date())
    else { return }
    let visible = visibleNodeIDs()
    briefingCards = activeFocusContext.isEmpty ? raw : raw.filter { visible.contains($0.node.id) }
    briefingMoved = briefingCards.filter { $0.movedSince > 0 }
    briefingQuiet = briefingCards.filter { $0.movedSince == 0 }
  }

  /// Narrow refresh for the menu-bar glance: only what the popover shows (heartbeat + What's Next),
  /// skipping the briefing cards / forest that only the main window needs.
  func refreshGlance() {
    snapshot = MonitorSnapshot.gather(canonical: database, spool: spool)
    guard let database else { return }
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
      setAllNodes(fetched)
      pruneNarrationCache()
    }
    let visible = visibleNodeIDs()

    if let raw = try? SmartLists.compute(database, now: now) {
      lists = activeFocusContext.isEmpty ? raw : filtered(raw, visible)
    }
    // Briefing costs a query per active node and its pane is usually off screen, so it is refreshed
    // only while it IS the selection. Arriving on Briefing loads it through `loadBriefingCards()`,
    // which RootView calls — the same off-`body` shape the middle column's feeds already use.
    if sidebarSelection == .briefing { loadBriefingCards() }
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

  // MARK: - Behaviour that lives in sibling files
  // Stored state stays here; each block below moved out when this file hit SwiftLint's 400-line cap.
  // - AppModel+Middle.swift — `middleKind()`, `selectMiddleNode`, `middleTitle`,
  //   `detailShowsLooseEnds`, `projectCount`, and the node-tree accessors those read
  //   (`node(_:)`, `children(of:)`, `visibleChildren(of:)`, `visibleNodeIDs()`).
  // - AppModel+Organizing.swift — every organizing write, including the two modal commits, plus the
  //   shared refuse/fail/displayName/defaultKind/presentNewNode/presentEditNode helpers.
  // - AppModel+Search.swift — `isSearching` and the search machinery.
  // - AppModel+Lifecycle.swift — `start()`, the liveness wiring, and the three refresh entry points
  //   that own a whole store pass (`refreshNow`, the two watch-driven ones, the widget republish).
}

/// The key `displayed(field:sourceText:)`'s memo is stored under. A file-scope type rather than a
/// nested one: `AppModel` already nests `CachedNarration` and `SearchScope`, and SwiftLint caps
/// nesting at one level.
struct DisplayedTranslationKey: Hashable {
  let field: TranslationField
  let language: String
  let sourceText: String
}
