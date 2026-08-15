import ApplicationServices
import Cocoa

/// SwiftUI list rows expose no AXPress action — selection is driven by setting AXSelected on the
/// nearest AXRow ancestor. Measured, not assumed: an AXPress-based probe appears broken instead.
func selectRow(containing element: AccessibilityElement) -> Bool {
  guard let row = nearestAncestor(of: element, role: "AXRow") else { return false }
  return AXUIElementSetAttributeValue(row.element, kAXSelectedAttribute as CFString, true as CFTypeRef)
    == .success
}

/// Posts a real click at the element's centre. The general fallback for controls that are not rows.
func clickCentre(of element: AccessibilityElement, activating application: NSRunningApplication?) -> Bool {
  guard let frame = element.frame else { return false }
  let point = CGPoint(x: frame.midX, y: frame.midY)
  application?.activate()
  usleep(200_000)
  guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                mouseCursorPosition: point, mouseButton: .left),
        let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                              mouseCursorPosition: point, mouseButton: .left) else { return false }
  mouseDown.post(tap: .cghidEventTap)
  usleep(60_000)
  mouseUp.post(tap: .cghidEventTap)
  return true
}

private let namedKeys: [String: CGKeyCode] = [
  "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
  "left": 123, "right": 124, "down": 125, "up": 126,
  "f": 3, "g": 4, "n": 45, "r": 15, "k": 40, "i": 34,
]

/// Sends a chord such as `cmd+f`, `shift+cmd+g`, or a bare named key such as `escape`.
/// Anything not recognised as a chord is typed as literal text.
func sendChord(_ chord: String) -> Bool {
  let parts = chord.lowercased().split(separator: "+").map(String.init)
  guard let last = parts.last else { return false }

  guard let keyCode = namedKeys[last] else {
    // Not a known key — type it as literal text.
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return false }
    let characters = Array(chord.utf16)
    event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
    event.post(tap: .cghidEventTap)
    return true
  }

  var flags = CGEventFlags()
  for modifier in parts.dropLast() {
    switch modifier {
    case "cmd", "command": flags.insert(.maskCommand)
    case "shift": flags.insert(.maskShift)
    case "opt", "option", "alt": flags.insert(.maskAlternate)
    case "ctrl", "control": flags.insert(.maskControl)
    default: return false
    }
  }
  guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
        let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
  else { return false }
  keyDownEvent.flags = flags
  keyUpEvent.flags = flags
  keyDownEvent.post(tap: .cghidEventTap)
  usleep(40_000)
  keyUpEvent.post(tap: .cghidEventTap)
  return true
}

func captureWindow(_ window: PensieveWindow, to path: String) -> Bool {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  process.arguments = ["-x", "-o", "-l", String(window.windowIdentifier), path]
  do { try process.run() } catch { return false }
  process.waitUntilExit()
  return process.terminationStatus == 0
}
