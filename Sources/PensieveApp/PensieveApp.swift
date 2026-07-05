import AppKit
import Foundation
import SwiftUI
import PensieveKit

/// Resolves store locations the same way the CLI does (honors PENSIEVE_DB / PENSIEVE_CAPTURE_DB).
enum Stores {
  static var canonicalURL: URL {
    if let o = ProcessInfo.processInfo.environment["PENSIEVE_DB"] { return URL(fileURLWithPath: o) }
    return PensievePaths.canonicalURL()
  }
  static var spoolURL: URL {
    if let o = ProcessInfo.processInfo.environment["PENSIEVE_CAPTURE_DB"] { return URL(fileURLWithPath: o) }
    return PensievePaths.captureURL()
  }
}

/// Sets the Dock / ⌘-Tab icon at launch. Pensieve.app is an unbundled SwiftPM executable (no .app
/// bundle, so no asset-catalog icon yet — that arrives with the v0.2 bundling step). `applicationIconImage`
/// is the first-party way to set the running app's icon in the meantime; the artwork ships as a
/// SwiftPM resource loaded via `Bundle.module`.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillFinishLaunching(_ notification: Notification) {
    // Unbundled SwiftPM executables have no Info.plist to declare them a regular app, so AppKit
    // does NOT default to `.regular` — the process runs accessory-style with no Dock icon, no
    // ⌘-Tab entry, and no menu-bar ownership. The imperative bootstrap set this explicitly before
    // the App-lifecycle migration; restore it here so Pensieve is a normal foreground app.
    NSApplication.shared.setActivationPolicy(.regular)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
       let image = NSImage(contentsOf: url) {
      NSApplication.shared.applicationIconImage = image
    }
  }
}

@main
struct PensieveApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  // One AppModel for the app's lifetime. Its init reads/writes the lastOpenedAt UserDefault.
  @StateObject private var model = AppModel()

  var body: some Scene {
    // A single unique window — the correct primitive for one main window. Multi-window/tabbing is
    // slice 3's job; `Window` gives the standard menu bar, ⌘Q, and scene frame restoration for free.
    Window("Pensieve", id: "main") {
      RootView(model: model)
        .frame(minWidth: 720, minHeight: 420)
        .task { model.start() }   // idempotent (guarded in AppModel)
    }
    .defaultSize(width: 900, height: 560)
    .windowResizability(.contentMinSize)
    .commands {
      SidebarCommands()   // standard Show/Hide Sidebar (⌃⌘S) in the View menu
      CommandMenu("Go") {
        Button("Quick Jump…") { model.showPalette = true }
          .keyboardShortcut("k", modifiers: .command)
        Divider()
        Button("Refresh") { Task { await model.refreshNow() } }
          .keyboardShortcut("r", modifiers: .command)
      }
    }
  }
}
