// Sources/PensieveApp/NodeFindState.swift
import Foundation
import Observation
import PensieveKit

/// The find bar's per-window state. One instance per `DetailView`, published to the menu bar via
/// `.focusedSceneValue` so Edit ▸ Find acts on the FOCUSED scene — the main window and each ⌘⌥N
/// recall window each own their find.
///
/// All the interesting rules (ordinals, identity, wrap-around, re-anchoring) live in the tested
/// `FindSession` in PensieveKit. This class is the observable shell plus the app-only concerns:
/// presentation, the transcript sweep, and reaching a match that is not on screen yet.
@Observable
final class NodeFindState {
  /// The empty placeholder both `document` and `session` start from, before any node has loaded.
  private static let empty = NodeFindDocument.testing(units: [])

  var isPresented = false
  private(set) var query = ""
  /// The document find is matching against. Held here as well as inside `FindSession` so the
  /// transcript sweep can fill each loose end's provenance slot in place and hand the whole document
  /// back — the slots are pre-allocated, so a late fill cannot reorder the matches around it.
  private(set) var document = NodeFindState.empty
  private(set) var session = FindSession(document: NodeFindState.empty)

  /// Sweep progress, shown as "N matches · searching transcripts done/total".
  private(set) var sweepDone = 0
  private(set) var sweepTotal = 0

  /// The node this state belongs to. `DetailView`'s `@State` survives a node change (which is why
  /// the file is full of `loadedNodeID == node.id` guards), so find state must be reset explicitly
  /// or the bar reports the previous node's matches.
  private(set) var nodeID: UUID?

  /// Set when navigation targets an anchor whose view is not mounted yet; cleared by `siteMounted`.
  private(set) var pendingScroll: FindAnchor?
  /// Published once the target's view reports it mounted; `DetailView` turns it into `scrollTo`.
  var scrollTarget: FindAnchor?
  /// Loose-end rows find has force-expanded. Per-window on purpose: reusing the app-wide
  /// `AppModel.expandedLooseEndID` would expand the same row in every open recall window.
  private(set) var forcedExpansions: Set<UUID> = []

  /// The in-flight transcript sweep, and the generation it belongs to. A late result whose
  /// generation differs is dropped — same discipline as DetailView's `Task.isCancelled` guard.
  @ObservationIgnored var sweepTask: Task<Void, Never>?
  @ObservationIgnored private(set) var generation = 0

  var hasMatches: Bool { session.hasMatches }
  var matchCount: Int { session.matchCount }
  var currentOrdinal: Int? { session.currentOrdinal }
  var isSweeping: Bool { sweepTotal > 0 && sweepDone < sweepTotal }

  func present() { isPresented = true }

  func dismiss() {
    isPresented = false
    query = ""
    session.clear()
    forcedExpansions = []
    pendingScroll = nil
    cancelSweep()
  }

  /// Called when the pane's content loads or the node changes. Bumps the generation so a sweep
  /// started for the previous node can't write into this one.
  ///
  /// A genuine node change starts a fresh session (no query, no held position — there is no
  /// position to hold). A same-node document change (⌘R, narration arriving, later the transcript
  /// sweep) goes through `updateDocument`/`FindSession.update` instead, which is what preserves the
  /// user's current match identity across the document mutating underneath them.
  func reset(nodeID: UUID, document: NodeFindDocument) {
    generation += 1
    cancelSweep()
    let isNodeChange = self.nodeID != nodeID
    if isNodeChange {
      query = ""
      forcedExpansions = []
      pendingScroll = nil
      // `scrollTarget` too, not just the pending half: an armed scroll the `.onChange` has not
      // consumed yet would otherwise survive the node change — and because `.onChange` fires only on
      // a value CHANGE, re-arming that same anchor later would not fire at all.
      scrollTarget = nil
      isPresented = false
    }
    self.nodeID = nodeID
    // Zeroed on the same-node path too. `reset` rebuilds every provenance slot as unresolved AND
    // cancels the sweep above, so any in-flight progress describes work whose results are now
    // dropped — keeping the old numbers would show a bar that never finishes. The caller restarts
    // the sweep instead (`DetailView.resetFind`), which reports real numbers again.
    sweepDone = 0
    sweepTotal = 0
    self.document = document
    if isNodeChange {
      session = FindSession(document: document)
      session.setQuery(query)
    } else {
      updateDocument(document)
    }
  }

  func setQuery(_ newQuery: String) {
    query = newQuery
    session.setQuery(newQuery)
    focusCurrent()
  }

  func updateDocument(_ document: NodeFindDocument) {
    self.document = document
    session.update(document: document)
  }

  func next() { session.next(); focusCurrent() }
  func previous() { session.previous(); focusCurrent() }

  func noteSweepProgress(done: Int, total: Int) {
    sweepDone = done
    sweepTotal = total
  }

  func cancelSweep() {
    sweepTask?.cancel()
    sweepTask = nil
  }

  /// Loads every unresolved loose end's provenance and fills its document slot in place, so a phrase
  /// that exists only inside a transcript window — behind a collapsed row — is findable at all. The
  /// match count grows as sessions resolve, which is what the progress half of the bar reports.
  ///
  /// Carries the generation it started in and drops its results if that changed, so a sweep started
  /// for the previous node (or for the document this node had before a ⌘R) can never write into the
  /// current one — the same discipline as `DetailView`'s narration `Task.isCancelled` guard.
  @MainActor
  func startSweep(looseEnds: [LooseEndView], loader: ProvenanceLoader?) {
    guard let loader, isPresented else { return }
    let unresolved = Set(document.unresolvedLooseEndIDs)
    // The LIVE loose ends the pane is rendering, never `LoadedProvenance.context.looseEnd`: that
    // snapshot is pinned from the loader's first load, and `nodeID` is repointed by strand
    // materialization while `label` is rewritten by a thumbs tap.
    let pendingLooseEnds = looseEnds.map(\.looseEnd).filter { unresolved.contains($0.id) }
    guard !pendingLooseEnds.isEmpty else { return }
    cancelSweep()
    // A cancelled sweep's numbers must not survive into this one: the progress guard below is
    // monotonic within a single total, which only reads correctly from a clean slate.
    noteSweepProgress(done: 0, total: 0)
    let startedGeneration = generation
    let (progressReports, progressContinuation) = AsyncStream<SweepProgress>.makeStream()
    sweepTask = Task { [weak self] in
      // The load runs as a child task so its progress can be consumed while it is still going. It
      // reports through a stream rather than a closure over `self` on purpose: the loader's
      // `onProgress` is a non-isolated `@Sendable` closure, and this observable state is not
      // `Sendable`, so it must never be captured there.
      async let resolved = NodeFindState.resolveProvenance(pendingLooseEnds, from: loader,
                                                           reportingTo: progressContinuation)
      for await report in progressReports {
        guard let self, self.generation == startedGeneration else { continue }
        // `onProgress` reports (pathsDone, pathsTotal) over PENDING UNIQUE TRANSCRIPT PATHS, not
        // loose ends: the total shrinks as the loader's cache warms, and a fully cached call reports
        // (0, 0) — which means "nothing to do", not "0%". Within one sweep the total is fixed, and
        // each report crosses to the main actor independently, so a later one can land first: ignore
        // anything that would move the bar backwards.
        guard report.total != self.sweepTotal || report.done > self.sweepDone else { continue }
        self.noteSweepProgress(done: report.done, total: report.total)
      }
      let loaded = await resolved
      guard let self, self.generation == startedGeneration else { return }
      var filled = self.document
      for looseEnd in pendingLooseEnds {
        NodeFindState.fillProvenanceSlot(&filled, looseEndID: looseEnd.id,
                                         loaded: loaded[looseEnd.id], quote: looseEnd.quote)
      }
      self.updateDocument(filled)
    }
  }

  /// Re-resolves one loose end's provenance slot from the window a row has ACTUALLY loaded.
  ///
  /// The loader invalidates a cached window when its transcript's `(size, mtime)` changes, so a row
  /// expanding after the sweep can render a DIFFERENT window than the sweep recorded: messages
  /// appended since have no units, and neighbours that left the ±4 window are gone. Anchors are keyed
  /// on the parser's append-only `messageIndex`, so a shifted window can never misdirect a highlight
  /// onto the wrong segment — it only leaves the document stale. Letting the row correct it makes the
  /// rendered window the truth.
  ///
  /// A loose end that is no longer in the document is silently ignored (an unknown slot is a no-op),
  /// so a row task resolving after a node change cannot write into the new node's document.
  func noteRenderedProvenance(looseEndID: UUID, loaded: LoadedProvenance?, quote: String) {
    var updated = document
    NodeFindState.fillProvenanceSlot(&updated, looseEndID: looseEndID, loaded: loaded, quote: quote)
    updateDocument(updated)
  }

  /// Resolves one loose end's provenance slot: the transcript window's findable segments, or the
  /// stored quote when there is no window on screen to match against.
  ///
  /// The branch is on `transcriptAvailable`, NOT on whether the window yielded any findable units. A
  /// window of nothing but harness blocks yields no units, yet the row still renders those MESSAGES —
  /// indexing the stored quote there would mint a match that is nowhere on screen, so the count would
  /// include a match ⌘G can neither highlight nor scroll to.
  private static func fillProvenanceSlot(_ document: inout NodeFindDocument, looseEndID: UUID,
                                         loaded: LoadedProvenance?, quote: String) {
    guard let loaded, loaded.context.transcriptAvailable else {
      // No provenance at all, or an honestly-degraded row: the stored quote IS what is rendered.
      document.fillWithQuoteFallback(looseEndID: looseEndID, quote: quote)
      return
    }
    document.fill(looseEndID: looseEndID,
                  units: NodeFindDocument.units(from: loaded, looseEndID: looseEndID))
  }

  /// Runs the loader and then closes the progress stream, so the consuming loop always terminates.
  /// Static so the child task captures nothing but `Sendable` values.
  private static func resolveProvenance(
    _ looseEnds: [LooseEnd], from loader: ProvenanceLoader,
    reportingTo progress: AsyncStream<SweepProgress>.Continuation
  ) async -> [UUID: LoadedProvenance] {
    let loaded = await loader.load(all: looseEnds) { done, total in
      progress.yield(SweepProgress(done: done, total: total))
    }
    progress.finish()
    return loaded
  }

  /// One `onProgress` report, carried from the loader actor to the main actor.
  private struct SweepProgress: Sendable {
    let done: Int
    let total: Int
  }

  /// A site reports that it is now in the view hierarchy. When it is the one we're waiting for, the
  /// scroll fires. This replaces guessing at layout timing: a transcript unit is only in the
  /// document if the sweep already loaded and guarded it, so the site WILL mount once expansion is
  /// set.
  func siteMounted(_ anchor: FindAnchor) {
    guard pendingScroll == anchor else { return }
    pendingScroll = nil
    scrollTarget = anchor
  }

  /// Highlight runs for one anchor's text, or an empty array when nothing matches there.
  func runs(for anchor: FindAnchor, text: String) -> [FindRun] {
    guard !query.isEmpty else { return [] }
    let ranges = FindMatcher.ranges(in: text, query: query)
    guard !ranges.isEmpty else { return [] }
    return FindMatcher.runs(in: text, ranges: ranges)
  }

  /// The character offset of the current match, if it lives in this anchor — lets the renderer tint
  /// the current match more strongly than the rest.
  func currentOffset(in anchor: FindAnchor) -> Int? {
    guard let current = session.current, current.anchor == anchor else { return nil }
    return current.offset
  }

  /// Prepares to reveal the current match: force-expands its row and arms the pending scroll.
  private func focusCurrent() {
    guard let current = session.current else { pendingScroll = nil; return }
    if let looseEndID = current.anchor.looseEndID {
      forcedExpansions.insert(looseEndID)
    }
    pendingScroll = current.anchor
    // A site that is ALREADY mounted will not fire `onAppear` again, so publish the target
    // immediately too; `siteMounted` covers the not-yet-mounted case. Setting both is safe —
    // `scrollTo` on a present id is idempotent.
    scrollTarget = current.anchor
  }
}
