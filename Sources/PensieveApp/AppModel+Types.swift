// Sources/PensieveApp/AppModel+Types.swift
import Foundation
import SwiftUI
import PensieveKit

enum SmartListKind: String, CaseIterable, Hashable {
  case whatsNext, dormant, recentlyActive
  var title: String {
    switch self {
    case .whatsNext: return String(localized: "What's Next")
    case .dormant: return String(localized: "Dormant")
    case .recentlyActive: return String(localized: "Recently Active")
    }
  }
  var symbol: String {
    switch self {
    case .whatsNext: return "star"
    case .dormant: return "pause.circle"
    case .recentlyActive: return "dot.radiowaves.left.and.right"
    }
  }
  var color: Color {
    switch self {
    case .whatsNext: return .accentColor
    case .dormant: return .secondary
    case .recentlyActive: return .green
    }
  }
  /// Which bucket of `SmartLists` this kind selects.
  var itemsKeyPath: KeyPath<SmartLists, [NextItem]> {
    switch self {
    case .whatsNext: return \.whatsNext
    case .dormant: return \.dormant
    case .recentlyActive: return \.recentlyActive
    }
  }
}

enum SidebarSelection: Hashable {
  case briefing
  case reviewSuggestions
  /// The burn-down queue: every open loose end, suggested-salient first then oldest.
  case triage
  /// The record: loose ends already done or dropped, most recently closed first.
  case completed
  case smartList(SmartListKind)
  case node(UUID)
}

/// What the middle column shows for the current sidebar selection. `.looseEndsOf` carries the node id
/// so the view loads its loose ends off-`body` (via `.task`), never in a `body` DB query.
/// `.triage` / `.completed` are NOT `SmartListKind` cases: that enum's `itemsKeyPath` returns
/// `[NextItem]` (nodes), and these two buckets hold loose ends. `.reviewSuggestions` set the
/// precedent for a sidebar row that is not a smart list, so `DeepLink` stays untouched.
enum MiddleKind: Equatable {
  case nodes([Node])
  case looseEndsOf(UUID)
  case reviewSuggestions
  case triage
  case completed
}

/// A New/Edit modal request. Identifiable so it drives `.sheet(item:)`.
struct NodeEditRequest: Identifiable {
  enum Mode { case new(parent: UUID?); case edit(Node) }
  let mode: Mode
  var id: String {
    switch mode {
    case .new(let parentNodeID): return "new-\(parentNodeID?.uuidString ?? "root")"
    case .edit(let nodeToEdit): return "edit-\(nodeToEdit.id.uuidString)"
    }
  }
}

/// A ⌘K jump target. Navigation only — sets the same selection state the sidebar does.
enum PaletteDestination: Hashable {
  case node(UUID)
  case smartList(SmartListKind)
  case briefing

  @MainActor func apply(to model: AppModel) {
    switch self {
    case .node(let id):
      model.sidebarSelection = .node(id); model.selectedNodeID = id
    case .smartList(let kind):
      model.sidebarSelection = .smartList(kind); model.selectedNodeID = nil
    case .briefing:
      model.sidebarSelection = .briefing; model.selectedNodeID = nil
    }
  }
}

/// A user-facing failure from an organizing write. Two flavors, both surfaced the same way:
/// a REFUSAL (the command returned a non-success value — stale/guarded state) and a THROW (a real
/// DB error). Refusals get honest, non-alarming copy; throws append the underlying description.
struct AppError: Identifiable {
  let id = UUID()
  let title: String
  let message: String

  /// The node changed under the menu (deleted or re-parented between open and click).
  static func refusal(_ verb: String, _ name: String) -> AppError {
    AppError(title: String(localized: "Couldn’t \(verb) “\(name)”"),
             message: String(localized: "It may have changed since this menu opened. The view has been refreshed — try again."))
  }

  static func failure(_ verb: String, _ name: String, _ error: Error) -> AppError {
    AppError(title: String(localized: "Couldn’t \(verb) “\(name)”"),
             message: error.localizedDescription)
  }

  /// The new node's parent vanished under the menu. This case does NOT compose a verb into the shared
  /// refusal title: German needs a past participle in that passive frame, and "add a node under" is an
  /// infinitive with a trailing preposition — composing it produces an ungrammatical sentence. Its own
  /// complete key lets each language phrase the whole thing naturally.
  static func cannotAddUnder(_ parent: String) -> AppError {
    AppError(title: String(localized: "Couldn’t add a node under “\(parent)”"),
             message: String(localized: "It may have changed since this menu opened. The view has been refreshed — try again."))
  }
}
