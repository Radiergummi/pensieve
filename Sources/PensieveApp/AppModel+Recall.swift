// Sources/PensieveApp/AppModel+Recall.swift
import Foundation
import SwiftUI
import PensieveKit

extension AppModel {
  func detail(for node: Node) -> (status: ProjectStatus, looseEnds: [LooseEndView]) {
    let fallback = ProjectStatus(project: node, recentEvents: [])
    guard let database else { return (fallback, []) }
    let now = Date()
    let status = (try? ProjectQueries.status(database, node: node, limit: SummaryBuilder.narratableEventWindow)) ?? fallback
    let ends = (try? LooseEndQueries.open(database, nodeID: node.id, now: now)) ?? []
    return (status, ends)
  }

  /// The node's recall rendered as shareable English Markdown. Reuses `detail(for:)` for the gather
  /// and includes the narration only if it's already cached (a share never blocks on an LLM call).
  func recallMarkdown(for node: Node) -> String {
    let detail = detail(for: node)
    // Respect the narration display toggle: a disabled recap must not leak into a share/export.
    let narration = AppDefaults.narrationEnabled ? cachedNarration(for: node, events: detail.status.recentEvents) : nil
    return RecallMarkdown.render(node: node, narration: narration,
                                 looseEnds: detail.looseEnds, events: detail.status.recentEvents, now: Date())
  }

  /// Open loose ends for a node — the inspector's slice of `detail(for:)` (no status query).
  /// Loaded once per selection via the inspector's `.task`, never in a view `body`.
  func looseEnds(forNode nodeID: UUID) -> [LooseEndView] {
    guard let database else { return [] }
    return (try? LooseEndQueries.open(database, nodeID: nodeID, now: Date())) ?? []
  }

  /// The cross-node audit queue for the Review Suggestions surface. Loaded off-`body` via `.task`.
  func reviewItems() -> [LooseEndView] {
    guard let database else { return [] }
    return (try? SalienceReviewQueries.pending(database, now: Date())) ?? []
  }

  /// Confirm a user salience label for a loose end (👍 salient / 👎 noise / "" clears).
  func setLooseEndLabel(_ looseEndID: UUID, _ label: String) {
    guard let database else { return }
    do {
      let succeeded = try LooseEndCommands.setLabel(database, id: looseEndID, label: label)
      if !succeeded { refuse(String(localized: "update"), String(localized: "this loose end")) }
    } catch {
      fail(String(localized: "update"), String(localized: "this loose end"), error)
    }
  }

  /// Resolve or reopen a loose end, registering the inverse with the responder chain's undo manager.
  /// Undo is not polish here: triage is a rapid keyboard flow by design, so a mis-key must be one ⌘Z
  /// away. `previous` is passed in rather than re-read because the row already holds the snapshot,
  /// and re-reading after the write would record the NEW value as the thing to undo to.
  /// `previousResolvedAt` completes the pair undo must restore: `resolve` derives the stamp from the
  /// target status, so without it an undone done→dropped flip left the item stamped `now` and pinned
  /// to the top of the Completed feed. nil for a row that was open (the honest value).
  func resolveLooseEnd(_ looseEndID: UUID, _ status: LooseEndStatus,
                       previous: LooseEndStatus, previousResolvedAt: Date? = nil,
                       undoManager: UndoManager?) {
    guard let database else { return }
    do {
      let succeeded = try LooseEndCommands.resolve(database, id: looseEndID, status: status,
                                                  restoringResolvedAt: previousResolvedAt)
      if succeeded {
        // The index must not lag the write, and REOPENING is the direction that matters: a stale
        // `done` excludes live work from ⌥⌘F's default scope in SQL, where the resolver never gets a
        // candidate to admit, so the end becomes unfindable. (A stale `open` after a close is only
        // wasteful — the query's over-fetch backfills around it.) A targeted update rather than
        // `syncSearchIndexes()`, which rebuilds the whole corpus.
        searchStore.updateStatus(itemID: looseEndID.uuidString, status: status.rawValue)
        // The stamp this write just replaced is what the inverse must put back, so it is read from
        // the row BEFORE this write in the caller and threaded through, not re-derived here.
        undoManager?.registerUndo(withTarget: self) { [previousResolvedAt] model in
          model.resolveLooseEnd(looseEndID, previous, previous: status,
                                previousResolvedAt: previousResolvedAt, undoManager: undoManager)
        }
        undoManager?.setActionName(String(localized: "Resolve Loose End"))
        // Unlike `setLabel`, whose row re-filters on the next reload, the resolved row must leave the
        // open feed now — and `refresh()` alone cannot do that, because the feeds key their reload
        // `.task` on `refreshToken`, which means ⌘R and is deliberately not bumped here.
        looseEndRevision += 1
        refresh()
      } else {
        refuse(String(localized: "update"), String(localized: "this loose end"))
      }
    } catch {
      fail(String(localized: "update"), String(localized: "this loose end"), error)
    }
  }

  /// Close every open end on a node in one action, with ONE undo that reopens exactly the set it
  /// closed — not "reopen everything on this node", which would resurrect ends closed weeks ago.
  func closeAllLooseEnds(onNode nodeID: UUID, undoManager: UndoManager?) {
    guard let database else { return }
    do {
      let closed = try LooseEndCommands.resolveAllOpen(database, nodeID: nodeID, status: .done)
      for id in closed {
        searchStore.updateStatus(itemID: id.uuidString, status: LooseEndStatus.done.rawValue)
      }
      undoManager?.registerUndo(withTarget: self) { model in
        model.setLooseEnds(closed, to: .open, undoManager: undoManager)
      }
      undoManager?.setActionName(String(localized: "Close All Loose Ends"))
      looseEndRevision += 1
      refresh()
    } catch {
      fail(String(localized: "update"), String(localized: "this node"), error)
    }
  }

  /// Undo's inverse of `closeAllLooseEnds`, and its own inverse in turn: each direction registers the
  /// other, so ⌘Z / ⇧⌘Z toggles indefinitely. An earlier version had the redo closure re-close the
  /// set without registering anything, so the chain died after one cycle.
  ///
  /// Every end in `ids` was OPEN before the bulk close (`resolveAllOpen` only touches open rows, and
  /// an open row's `resolvedAt` is nil by construction), so reopening needs no stamp to restore.
  private func setLooseEnds(_ ids: [UUID], to status: LooseEndStatus, undoManager: UndoManager?) {
    guard let database else { return }
    do {
      var refused = 0
      for id in ids {
        if try LooseEndCommands.resolve(database, id: id, status: status) {
          searchStore.updateStatus(itemID: id.uuidString, status: status.rawValue)
        } else {
          refused += 1   // deleted or merged away since the action — not a failure
        }
      }
      let inverse: LooseEndStatus = status == .open ? .done : .open
      undoManager?.registerUndo(withTarget: self) { model in
        model.setLooseEnds(ids, to: inverse, undoManager: undoManager)
      }
      undoManager?.setActionName(String(localized: "Close All Loose Ends"))
      looseEndRevision += 1
      refresh()
      // Surfaced rather than swallowed: the sibling organizing writes retired `try?` for exactly this
      // classification, and a silent undo that did nothing is worse here than a plain notice.
      if refused > 0 { refuse(String(localized: "update"), String(localized: "this node")) }
    } catch {
      fail(String(localized: "update"), String(localized: "this node"), error)
    }
  }

  /// Names the count, because the bulk verb deliberately does not show the items first.
  func bulkCloseConfirmationText() -> String {
    guard let id = pendingBulkCloseNodeID else { return "" }
    let count = nodeRowFacts[id]?.openLooseEnds ?? 0
    return String(localized: "Close \(count) loose ends?")
  }

  /// The burn-down queue. Focus-scoped like every other list; the Kit query adds active-node scoping.
  func triageItems() -> [LooseEndView] {
    guard let database else { return [] }
    return (try? LooseEndQueries.openAcrossNodes(database, visibleNodeIDs: visibleNodeIDs(),
                                                 now: Date())) ?? []
  }

  /// Closed loose ends across all projects, most recently resolved first.
  func completedItems() -> [LooseEndView] {
    guard let database else { return [] }
    return (try? LooseEndQueries.closedAcrossNodes(database, visibleNodeIDs: visibleNodeIDs(),
                                                   now: Date())) ?? []
  }

  /// One node's closed loose ends — the detail pane's collapsed record.
  func closedLooseEnds(forNode nodeID: UUID) -> [LooseEndView] {
    guard let database else { return [] }
    return (try? LooseEndQueries.closed(database, nodeID: nodeID, now: Date())) ?? []
  }

  /// Land the detail pane on a feed row's loose end. Deliberately does NOT change `sidebarSelection`:
  /// the queue must stay in the middle column, or every decision would cost you your place in it.
  /// Same two writes as `selectSearchHit`'s loose-end branch, which lands the same way from search.
  func focusLooseEnd(_ looseEnd: LooseEnd) {
    selectedNodeID = looseEnd.nodeID
    expandedLooseEndID = looseEnd.id
  }

  /// Surrounding-transcript provenance for a loose end, plus its parsed segments — resolved off the
  /// main actor (file I/O) by a shared `ProvenanceLoader`, so N rows from one session cost one parse.
  /// nil only when there is no database or the source event is missing; a present-but-unavailable
  /// transcript returns a context with `transcriptAvailable == false`.
  func provenance(for looseEnd: LooseEnd) async -> LoadedProvenance? {
    guard let provenanceLoader else { return nil }
    return await provenanceLoader.load(looseEnd)
  }
}
