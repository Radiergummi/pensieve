// Sources/PensieveApp/DeepLinkNavigation.swift
import SwiftUI
import AppKit
import PensieveKit

extension PaletteDestination {
  /// Maps a cross-surface DeepLink to the app's nav-only destination. Exhaustive over DeepLink so a
  /// future case fails to compile here (no silent drift). `.looseEnd` has no nav-only destination —
  /// it is routed via `AppModel.openLooseEnd` in `applyDeepLink`, so this returns nil for it.
  init?(_ link: DeepLink) {
    switch link {
    case .briefing:
      self = .briefing
    case .node(let id):
      self = .node(id)
    case .smartList(let smartListKind):
      switch smartListKind {
      case .whatsNext: self = .smartList(.whatsNext)
      case .dormant: self = .smartList(.dormant)
      case .recentlyActive: self = .smartList(.recentlyActive)
      }
    case .looseEnd:
      return nil
    }
  }
}

/// The single navigation entry point for both internal menu-bar clicks and external `pensieve://`
/// opens: bring up the main window, front the app, and apply the destination via the existing ⌘K
/// path (`PaletteDestination.apply`, which sets both sidebarSelection and selectedNodeID) — or, for
/// a loose-end link, via `AppModel.openLooseEnd` (no nav-only destination exists for it).
@MainActor
func applyDeepLink(_ link: DeepLink, model: AppModel, openWindow: OpenWindowAction) {
  openWindow(id: "main")
  NSApplication.shared.activate()   // macOS 14 cooperative form (not ignoringOtherApps:)
  if case .looseEnd(let id) = link {
    model.openLooseEnd(id)
  } else if let dest = PaletteDestination(link) {
    dest.apply(to: model)
  }
}
