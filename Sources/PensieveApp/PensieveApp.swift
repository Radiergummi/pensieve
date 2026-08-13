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
        .softScrollEdges()
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
        Button("New Node") { model.presentNewNodeAtSelection() }
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
      Group {
        if let nodeID {
          RecallWindowView(model: model, nodeID: nodeID)
        } else {
          ContentUnavailableView("No project", systemImage: "questionmark.folder")
        }
      }
      .softScrollEdges()
    }

    MenuBarExtra {
      MenuBarView(model: model)
    } label: {
      MenuBarLabel(model: model, appDelegate: appDelegate)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(model: model)
        .softScrollEdges()
    }
  }
}

/// Scroll-edge material, applied once per scene rather than per scroll view.
///
/// `.scrollEdgeEffectStyle` propagates to the scroll views *below* it — the four call sites this
/// replaced already relied on that, attaching to a `Group` and a `ScrollViewReader` rather than to
/// any scroll view itself. Hoisting it to the scene root is the same mechanism at a wider radius, and
/// it closes the gap the per-site version left: the Settings forms, the Move/Merge pickers (lists
/// scrolling under a `navigationTitle`), the node editor, and the icon-picker grids were all
/// untreated, and a scroll view added tomorrow inherits this instead of depending on someone
/// remembering.
///
/// **This is the part a green build cannot check.** If propagation does not reach a surface — the
/// sheet- and popover-presented content is the unverified case — the effect silently disappears from
/// columns that used to have it, and the failure looks exactly like success, because the
/// `.automatic` default also renders something. The honest test is a comparison: toggle `.soft` to
/// `.hard` here, rebuild, and confirm the top band visibly changes on each surface. If it does not
/// hold up, reverting to the four per-site calls is clean and loses nothing but the inheritance.
private extension View {
  func softScrollEdges() -> some View { scrollEdgeEffectStyle(.soft, for: .top) }
}
