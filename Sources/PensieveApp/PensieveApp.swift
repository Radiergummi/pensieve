import AppKit
import Foundation
import SwiftUI
import PensieveKit

@main
struct PensieveApp: App {
  // One AppModel for the app's lifetime. Its init reads/writes the lastOpenedAt UserDefault.
  @State private var model = AppModel()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  // Launch-time relocation state. `pendingRelocation` is read once, at launch — it drives whether
  // the relocation runs at all this session, never whether it is STILL pending (the persisted key
  // is the only thing `RelocationLauncher.clearPending()` can act on). `relocationAttempted` is a
  // one-shot guard: the Window's content can be torn down and recreated (⌘W then reopen) without
  // the App struct itself restarting, and a second run would find the destination already IS the
  // source and fail. `relocationFinished` — not a `fraction == 1` inference — is the completion
  // signal: each `progress()` call enqueues its own `Task { @MainActor in }`, and same-priority
  // ordering across those is a runtime detail, not a guarantee, so a late one landing after the
  // synchronous "done" write must not resurrect the blocking screen.
  @State private var relocationFraction: Double = 0
  @State private var relocationFinished = false
  @State private var relocationFailure: String?
  @State private var relocationRecoveryIncomplete = false
  @State private var relocationAcknowledged = false
  @State private var relocationAttempted = false
  private let pendingRelocation = RelocationLauncher.pendingDestination()

  var body: some Scene {
    // A single unique window — the correct primitive for one main window. `Window` gives the standard
    // menu bar, ⌘Q, and scene frame restoration for free. A real .app bundle makes the app `.regular`
    // by default, so no manual activation-policy is needed; the icon comes from the bundled .icon.
    Window("Pensieve", id: "main") {
      // The relocation must finish — success or failure — before RootView (and therefore
      // AppModel.start(), driven from RootView's own .task) is ever reached. That ordering is
      // the whole point of running this at launch: nothing is open yet to tear down. A failure or
      // a kept-old-folder note holds this screen (with a Continue affordance) rather than handing
      // control to RootView silently — `performRelocation` also starts AppModel directly on both
      // exits, so the app is never left with a screen that says "nothing works" AND is telling
      // the truth.
      Group {
        if let pendingRelocation, !relocationFinished {
          RelocationProgressView(destination: pendingRelocation.path,
                                 fraction: relocationFraction, failure: nil)
        } else if let relocationFailure, !relocationAcknowledged {
          RelocationProgressView(destination: pendingRelocation?.path ?? "",
                                 fraction: 1, failure: relocationFailure,
                                 onContinue: { relocationAcknowledged = true })
        } else if relocationRecoveryIncomplete, !relocationAcknowledged {
          RelocationProgressView(destination: pendingRelocation?.path ?? "",
                                 fraction: 1, failure: nil, recoveryIncomplete: true,
                                 onContinue: { relocationAcknowledged = true })
        } else {
          RootView(model: model)
            .task { model.start() }   // idempotent (guarded in AppModel)
        }
      }
      // Honest minimum = content.min (240) + detail.min (360) + inspector.min (260) = 860 — the
      // widest always-reachable config (inspector open, sidebar auto-collapsed). This floors the
      // window so no state clips; the sidebar (200) fits on top whenever the window is wider.
      .frame(minWidth: 860, minHeight: 480)
      .softScrollEdges()
      .task {
        // One-shot: closing and reopening this window recreates its content (and re-runs .task)
        // without restarting the App itself, and a second run would find the destination already
        // IS the source.
        guard let pendingRelocation, !relocationAttempted else { return }
        relocationAttempted = true
        await performRelocation(to: pendingRelocation)
      }
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

  /// Runs before `AppModel.start()` — nothing is open yet, which is what makes this safe.
  /// The pending key is cleared on EVERY exit path: a key surviving a failure would retry the
  /// move on every launch forever. `error` is not assumed to be a `RelocationError` — a source
  /// folder with a spool but no canonical store throws a raw GRDB error instead.
  ///
  /// `model.start()` is called directly on BOTH exits rather than left to RootView's own `.task`:
  /// a failure (or a kept-old-folder note) holds the Window on this screen, possibly forever if
  /// the user never dismisses it, and `MenuBarLabel`'s own `start()` call already ran once (guarded
  /// off) and does not fire again on a long-lived label view. Calling it here means the rest of the
  /// app — the menu bar's snapshot, a Continue tap into RootView — works regardless of whether or
  /// when the blocking screen is dismissed. `AppModel.start()` is idempotent, so this never double-runs.
  @MainActor
  private func performRelocation(to destination: URL) async {
    let source = PensievePaths.supportDirectory()
    do {
      let report = try await StoreRelocator(
        source: source, destination: destination,
        recycle: { NSWorkspace.shared.recycle([$0], completionHandler: nil); return true }
      ).run(progress: { fraction in
        Task { @MainActor in relocationFraction = fraction }
      })
      RelocationLauncher.clearPending()
      relocationRecoveryIncomplete = report.recoveryIncomplete
      relocationFinished = true
      model.start()
    } catch {
      RelocationLauncher.clearPending()
      relocationFailure = String(describing: error)
      relocationFinished = true
      model.start()
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
