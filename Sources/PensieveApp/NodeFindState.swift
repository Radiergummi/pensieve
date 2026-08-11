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
  var isPresented = false
  private(set) var query = ""
  private(set) var session = FindSession(document: NodeFindDocument.testing(units: []))

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
      isPresented = false
    }
    self.nodeID = nodeID
    sweepDone = 0
    sweepTotal = 0
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
