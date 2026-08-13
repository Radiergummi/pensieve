import Foundation
import SwiftUI
import PensieveKit

/// Resolves store locations the same way the CLI does (honors PENSIEVE_DB / PENSIEVE_CAPTURE_DB).
enum Stores {
  static var canonicalURL: URL {
    if let overridePath = ProcessInfo.processInfo.environment["PENSIEVE_DB"] { return URL(fileURLWithPath: overridePath) }
    return PensievePaths.canonicalURL()
  }
  static var spoolURL: URL {
    if let overridePath = ProcessInfo.processInfo.environment["PENSIEVE_CAPTURE_DB"] { return URL(fileURLWithPath: overridePath) }
    return PensievePaths.captureURL()
  }
}

@main
struct PensieveApp: App {
  // One AppModel for the app's lifetime. Its init reads/writes the lastOpenedAt UserDefault.
  @State private var model = AppModel()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    // A single unique window — the correct primitive for one main window. `Window` gives the standard
    // menu bar, ⌘Q, and scene frame restoration for free. A real .app bundle makes the app `.regular`
    // by default, so no manual activation-policy is needed; the icon comes from the bundled .icon.
    Window("Pensieve", id: "main") {
      RootView(model: model)
        // Honest minimum = content.min (240) + detail.min (360) + inspector.min (260) = 860 — the
        // widest always-reachable config (inspector open, sidebar auto-collapsed). This floors the
        // window so no state clips; the sidebar (200) fits on top whenever the window is wider.
        .frame(minWidth: 860, minHeight: 480)
        .task { model.start() }   // idempotent (guarded in AppModel)
    }
    .defaultSize(width: 1040, height: 660)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Pensieve") { AppInfo.showAboutPanel() }
      }
      SidebarCommands()   // standard Show/Hide Sidebar (⌃⌘S) in the View menu
      FindCommands()
      LooseEndResolveCommands()
      CommandGroup(after: .newItem) {
        Button("New Node") { model.presentNewNode(under: nil) }
          .keyboardShortcut("n", modifiers: .command)
        Button("Open in New Window") { model.openNodeRequest = model.selectedNodeID }
          .keyboardShortcut("n", modifiers: [.command, .option])
          .disabled(model.selectedNodeID == nil)
      }
      CommandMenu("Go") {
        Button("Search Everything") { model.focusSearchRequested = true }
          .keyboardShortcut("f", modifiers: [.command, .option])
        Divider()
        Button("Refresh") { Task { await model.refreshNow() } }
          .keyboardShortcut("r", modifiers: .command)
      }
    }

    WindowGroup("Recall", id: "recall", for: UUID.self) { $nodeID in
      if let nodeID {
        RecallWindowView(model: model, nodeID: nodeID)
      } else {
        ContentUnavailableView("No project", systemImage: "questionmark.folder")
      }
    }

    MenuBarExtra {
      MenuBarView(model: model)
    } label: {
      MenuBarLabel(model: model, appDelegate: appDelegate)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(model: model)
    }
  }
}
