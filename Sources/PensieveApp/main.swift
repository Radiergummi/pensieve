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

@MainActor
final class HeartbeatModel: ObservableObject {
  @Published var snapshot: MonitorSnapshot =
    .init(status: .notSetUp, lastCaptureAt: nil, spoolPending: 0, eventCount: 0, looseEndCount: 0)
  private var timer: Timer?

  func start() {
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }
  func refresh() {
    snapshot = MonitorSnapshot.gather(canonicalURL: Stores.canonicalURL, spoolURL: Stores.spoolURL)
  }
}

struct HeartbeatView: View {
  @ObservedObject var model: HeartbeatModel

  private var dot: (String, Color) {
    switch model.snapshot.status {
    case .active:   return ("● active", .green)
    case .idle:     return ("○ idle", .secondary)
    case .notSetUp: return ("⚠ not set up", .orange)
    }
  }
  private var lastCaptureLine: String {
    guard let at = model.snapshot.lastCaptureAt else { return "no captures yet" }
    let f = RelativeDateTimeFormatter()
    return "last capture \(f.localizedString(for: at, relativeTo: Date()))"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(dot.0).foregroundStyle(dot.1).font(.headline)
      Text(lastCaptureLine).foregroundStyle(.secondary).font(.subheadline)
      Divider()
      Text("Spool:  \(model.snapshot.spoolPending) pending").monospacedDigit()
      Text("Events: \(model.snapshot.eventCount)").monospacedDigit()
      Text("Loose ends: \(model.snapshot.looseEndCount)").monospacedDigit()
    }
    .padding(20)
    .frame(width: 280, alignment: .leading)
  }
}

// A plain (unbundled) NSApplication host — no Xcode/app bundle required for the dev workflow.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let model = HeartbeatModel()
model.start()
let window = NSWindow(
  contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
  styleMask: [.titled, .closable, .miniaturizable],
  backing: .buffered, defer: false)
window.title = "Pensieve"
window.center()
window.contentView = NSHostingView(rootView: HeartbeatView(model: model))
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
