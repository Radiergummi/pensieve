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

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let model = AppModel()
model.start()
let window = NSWindow(
  contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
  styleMask: [.titled, .closable, .miniaturizable, .resizable],
  backing: .buffered, defer: false)
window.title = "Pensieve"
window.center()
// Host via a controller (not `contentView = NSHostingView`) so AppKit propagates the titlebar
// safe-area inset — otherwise the full-height sidebar scrolls up under the traffic-light chrome.
window.contentViewController = NSHostingController(rootView: RootView(model: model))
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
