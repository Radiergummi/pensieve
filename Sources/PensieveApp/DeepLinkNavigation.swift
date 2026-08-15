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
  dismissMenuBarPopover()
  openWindow(id: "main")
  frontTheApp()
  if case .looseEnd(let id) = link {
    model.openLooseEnd(id)
  } else if let dest = PaletteDestination(link) {
    dest.apply(to: model)
  }
}

/// Bring Pensieve to the front, for real.
///
/// `NSApplication.shared.activate()` — the macOS 14 cooperative form that used to be called here —
/// **declines when another app is frontmost**, which is exactly the case where fronting is the whole
/// point. Measured 2026-08-15 by logging window state through this function: identical activations
/// alternated between raising the window and merely giving it key status behind other apps, tracking
/// only whether Pensieve happened to be active already. From a menu-bar popover it usually is not.
///
/// `NSRunningApplication.current.activate(options:)` is the non-deprecated route that actually
/// raises. `.activateIgnoringOtherApps` IS deprecated in macOS 14; `.activateAllWindows` is not, and
/// is what carries the window up rather than merely focusing it.
@MainActor
private func frontTheApp() {
  NSRunningApplication.current.activate(options: [.activateAllWindows])
}

/// Close the menu-bar popover if it is open, by clicking the status item — the same path a user
/// takes.
///
/// `MenuBarExtra(.window)` exposes no first-party dismissal: its `isInserted:` binding controls
/// whether the item EXISTS, not whether the popover is showing, and there is no presentation binding
/// in the SDK (checked against the SwiftUI `.swiftinterface` for MacOSX26.5).
///
/// The first attempt closed the `NSPanel` directly. That worked visually and was wrong: SwiftUI still
/// believed the popover was presented, so the status item kept its highlight and the next click was
/// spent resyncing rather than opening — one dead click every time. Driving the button instead lets
/// SwiftUI toggle its own state, which is the state that was out of sync.
///
/// `NSStatusBarButton` is public AppKit, unlike the private `MenuBarExtraWindow<AnyView>` the first
/// version had to identify by window level. The `.on` check is both the "is it open" test and the
/// guard that keeps this a no-op for external `pensieve://` opens — and it is precisely the
/// highlight that was being left behind.
@MainActor
func dismissMenuBarPopover() {
  guard let button = statusItemButton(), button.state == .on else { return }
  button.performClick(nil)
}

@MainActor
private func statusItemButton() -> NSStatusBarButton? {
  for window in NSApplication.shared.windows {
    if let contentView = window.contentView, let button = findStatusBarButton(contentView) {
      return button
    }
  }
  return nil
}

@MainActor
private func findStatusBarButton(_ view: NSView) -> NSStatusBarButton? {
  if let button = view as? NSStatusBarButton { return button }
  for subview in view.subviews {
    if let button = findStatusBarButton(subview) { return button }
  }
  return nil
}
