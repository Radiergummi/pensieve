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
  private var buffered: [DeepLink] = []

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      guard let link = DeepLink(url: url) else { continue }
      if let model {
        model.pendingDeepLink = link
      } else {
        buffered.append(link)
      }
    }
  }

  private func flush() {
    guard let model, let last = buffered.last else { return }
    model.pendingDeepLink = last   // most recent wins; earlier buffered links are superseded
    buffered.removeAll()
  }
}
