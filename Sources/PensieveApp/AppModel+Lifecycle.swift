// Sources/PensieveApp/AppModel+Lifecycle.swift
import Foundation
import SwiftUI
import SQLiteData
import GRDB
import PensieveKit
import WidgetKit

/// Launch, the liveness wiring, and the three refresh entry points that own a whole store pass.
/// Split out of `AppModel.swift` when the batched-aggregate and busy-loop fixes pushed that file past
/// SwiftLint's 400-line cap — the seam the quality sweep named, and the same reason
/// `AppModel+Middle.swift` and `AppModel+Organizing.swift` already exist. Stored state stays on the
/// class; the properties this file reaches for lost their `private` for that reason and no other.
extension AppModel {
  func start() {
    guard !started else { return }
    // `start()` is reachable from three places — the main window's RootView, the always-mounted
    // menu-bar label (so What's Next isn't empty even if the main window never opened), and a
    // recall window — and only the FIRST of those is gated on a launch-time relocation finishing.
    // Without this guard the menu-bar label would open the OLD store while the relocation is still
    // copying it. `started` is deliberately left false so whichever call happens once the pending
    // key clears still runs normally.
    guard RelocationLauncher.pendingDestination() == nil else { return }
    started = true
    AppLog.app.info("App started, canonical=\(resolvedCanonicalURL().path, privacy: .public) spool=\(resolvedSpoolURL().path, privacy: .public)")
    // Open the canonical store read/write (needed for the launch drain). A missing store degrades to
    // an empty window — but "broken" must not look like "empty": in a tool whose job is telling you
    // what you were doing, an unreadable or permission-denied store rendering as "no projects yet"
    // with nothing in the log is the failure mode this whole app is supposed to not have.
    do {
      database = try openCanonicalDatabase(at: resolvedCanonicalURL())
    } catch {
      database = nil
      AppLog.app.error("""
        Canonical store could not be opened at \
        \(resolvedCanonicalURL().path, privacy: .public): \(error, privacy: .public) — \
        the window will render empty
        """)
    }
    loadNarrationCache()
    spool = try? CaptureSpool(at: resolvedSpoolURL())   // persistent — see the property note above
    activeFocusContext = UserDefaults.standard.string(forKey: PensieveDefaults.activeFocusContextKey) ?? ""
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
    let canonicalDir = resolvedCanonicalURL().deletingLastPathComponent().path
    let spoolDir = resolvedSpoolURL().deletingLastPathComponent().path
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

    // Idle translation. App-lifetime like the watchers above: the corpus grows with every sync, so
    // this is a standing job, not a launch-time one.
    let translationScheduler = TranslationActivityScheduler(model: self)
    translationScheduler.start()
    translationActivityScheduler = translationScheduler
    AppLog.app.info("Idle translation scheduled")
  }

  /// On-demand equivalent of the launch drain+refresh, for the ⌘R Refresh menu command.
  ///
  /// The flag exists for the menu-bar popover, where this command is otherwise indistinguishable from
  /// a no-op: a drain that finds nothing new changes nothing on screen, correctly, and the user has no
  /// way to tell that apart from a dead button. Deliberately NOT a guard against re-entry — ⌘R while
  /// a refresh runs should still queue a second drain; this only reports. Two overlapping calls (⌘R
  /// plus the popover button) will therefore clear the flag when the FIRST finishes, stopping the
  /// spinner early. A counter would fix that, and is not worth it for a spinner.
  func refreshNow() async {
    isRefreshing = true
    defer { isRefreshing = false }
    await drainThenRefresh()
  }

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
    await reindexSpotlight()   // launch + ⌘R
    syncSearchIndexes()   // see AppModel+Search.swift
    republishWidgetDigest()
  }

  /// Watch-triggered drain: ingest new spool rows on our own connection. The resulting canonical
  /// change trips ValueObservation + the canonical watch → refreshDebouncer. Does NOT clear the
  /// narration cache or bump refreshToken (those are launch/⌘R semantics).
  func drainThenRefreshFromWatch() async {
    AppLog.app.debug("Spool watcher fired -> drain")
    if let database, let spool {
      _ = try? await Ingester(spool: spool, database: database).drain()
    }
  }

  /// Watch-triggered refresh: recompute state on the main actor, then reindex Spotlight. Kept as one
  /// @MainActor method so the debouncer's `await self?.refreshFromWatch()` needs no `MainActor.run`
  /// wrapper nor a nested `Task` — the nested Task captured the weak-`self` var in concurrently
  /// executing code, which is an error under the Swift 6 language mode.
  func refreshFromWatch() async {
    AppLog.app.debug("Canonical watcher fired -> refresh")
    refresh()
    syncSearchIndexes()   // work just drained must become findable without waiting for ⌘R
    await reindexSpotlight()
    republishWidgetDigest()
  }

  /// Spotlight reads through the ALREADY-OPEN canonical connection, never a fresh one.
  ///
  /// This is the same rule `MonitorSnapshot.gather(canonical:spool:)` states and `refresh()` obeys:
  /// this method is reached from `refreshFromWatch()`, which the support-directory FSEvents watch
  /// triggers, so opening a new connection here touched the `-shm`/`-wal` sidecars in the very
  /// directory being watched and re-fired the watch — a busy-loop that showed up in the field as two
  /// MetricKit CPU-exception payloads (90 s of CPU inside a 160 s sample, FSEvents frames in the
  /// stack). Read-only work, so the writer connection satisfies it without any new access.
  private func reindexSpotlight() async {
    guard let database else { return }
    await SpotlightIndexer.reindex(database: database, activeContext: activeFocusContext)
  }

  /// Digest + reload, always together, after each of the three refreshes that own a whole store pass. Fed from the
  /// `lists.whatsNext` that `refresh()` just computed: re-deriving it would put the whole ranking scan back on the main
  /// actor for an answer in hand. The reload stays app-side — one an agent requests is not dependable.
  private func republishWidgetDigest() {
    guard database != nil else { return }   // no store ⇒ `lists` is empty, and an empty digest renders as "Nothing open"
    WidgetDigestPublisher.publishQuietly(items: lists.whatsNext, activeContext: activeFocusContext)
    WidgetCenter.shared.reloadAllTimelines()
  }

  /// UserDefaults changed — if the active Focus context flipped, re-filter the window + reindex.
  private func focusContextDidChange() {
    let new = UserDefaults.standard.string(forKey: PensieveDefaults.activeFocusContextKey) ?? ""
    guard new != activeFocusContext else { return }
    AppLog.app.info("Focus context changed: '\(self.activeFocusContext, privacy: .public)' -> '\(new, privacy: .public)'")
    activeFocusContext = new
    refresh()
    republishWidgetDigest()   // AFTER refresh(): that is what re-filters the list to the new context
    if let database {
      Task { await SpotlightIndexer.reindex(database: database, activeContext: new) }
    }
  }
}
