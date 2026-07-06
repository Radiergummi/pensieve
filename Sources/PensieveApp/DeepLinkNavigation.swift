// Sources/PensieveApp/DeepLinkNavigation.swift
import SwiftUI
import AppKit
import PensieveKit

extension PaletteDestination {
  /// Maps a cross-surface DeepLink to the app's navigation destination. Exhaustive on both enums so
  /// a future smart list fails to compile here (no silent drift).
  init(_ link: DeepLink) {
    switch link {
    case .briefing:
      self = .briefing
    case .node(let id):
      self = .node(id)
    case .smartList(let s):
      switch s {
      case .whatsNext: self = .smartList(.whatsNext)
      case .dormant: self = .smartList(.dormant)
      case .recentlyActive: self = .smartList(.recentlyActive)
      }
    }
  }
}

/// The single navigation entry point for both internal menu-bar clicks and external `pensieve://`
/// opens: bring up the main window, front the app, and apply the destination via the existing ⌘K
/// path (`PaletteDestination.apply`, which sets both sidebarSelection and selectedNodeID).
@MainActor
func applyDeepLink(_ link: DeepLink, model: AppModel, openWindow: OpenWindowAction) {
  let dest = PaletteDestination(link)
  openWindow(id: "main")
  NSApplication.shared.activate()   // macOS 14 cooperative form (not ignoringOtherApps:)
  dest.apply(to: model)
}
