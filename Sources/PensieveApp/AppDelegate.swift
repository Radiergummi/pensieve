// Sources/PensieveApp/AppDelegate.swift
import AppKit
import PensieveKit

/// Receives external `pensieve://` opens. This is a scene-independent entry point that fires
/// regardless of whether the main window is open (a menu-bar app commonly runs with no window), so
/// it does not depend on any SwiftUI view being mounted. It parses each URL to a DeepLink and hands
/// it to the shared AppModel; if the model isn't wired yet (app launched *by* the URL), it buffers
/// and flushes once the model is set.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel? {
    didSet { flush() }
  }
  private var buffered: DeepLink?   // holds a link that arrived before the model was wired (most recent wins)

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      guard let link = DeepLink(url: url) else { continue }
      receive(link)
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    applyDockVisibility()
  }

  /// Reads the shared hide-Dock preference and sets the activation policy. `.accessory` hides
  /// the Dock tile + ⌘-Tab entry (menu-bar-only); the MenuBarExtra keeps the app alive.
  func applyDockVisibility() {
    let hidden = UserDefaults.standard.bool(forKey: AppDefaults.hideDockIconKey)
    NSApp.setActivationPolicy(hidden ? .accessory : .regular)
  }

  /// Single entry point for a resolved deep link — from an external `pensieve://` open OR an App
  /// Intent's `perform()`. Forwards to the wired model, else buffers until the model is set.
  func receive(_ link: DeepLink) {
    if let model {
      model.pendingDeepLink = link
    } else {
      buffered = link
    }
  }

  private func flush() {
    guard let model, let link = buffered else { return }
    model.pendingDeepLink = link
    buffered = nil
  }
}
