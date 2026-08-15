import Cocoa
import Foundation

func failWith(_ message: String) -> Never {
  FileHandle.standardError.write(Data(("uiprobe: " + message + "\n").utf8))
  exit(1)
}

func flagValue(_ name: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

let usage = """
usage: uiprobe <command> [options]

  windows                                  list Pensieve windows (pid, id, title, bounds)
  dump    [--pid N] [--depth N] [--grep P] print the accessibility tree
  find    <text> [--pid N]                 locate an element by exact label
  select  <text> [--pid N]                 select the nearest AXRow ancestor
  click   <text> [--pid N]                 synthetic click at the element's centre
  key     <chord> [--pid N]                send keys, e.g. cmd+f / escape / "some text"
  shot    [--pid N] [--out PATH]           capture the window to PNG

An empty window title in `windows` means Screen Recording is not granted.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { print(usage); exit(2) }

let explicitPID = flagValue("--pid", in: arguments).flatMap { pid_t($0) }

func targetPID() -> pid_t {
  switch resolveTargetProcess(explicit: explicitPID) {
  case .success(let pid): return pid
  case .failure(let failure): failWith(failure.message)
  }
}

func printTree(_ element: AccessibilityElement, depth: Int, maxDepth: Int, into lines: inout [String]) {
  lines.append(String(repeating: "  ", count: depth) + element.descriptionLine)
  guard depth < maxDepth else { return }
  for child in element.children {
    printTree(child, depth: depth + 1, maxDepth: maxDepth, into: &lines)
  }
}

switch command {
case "windows":
  let windows = pensieveWindows()
  if windows.isEmpty { failWith("no Pensieve windows on screen") }
  for window in windows {
    let title = window.title.isEmpty ? "<no title — Screen Recording not granted>" : window.title
    print("pid=\(window.processIdentifier) window=\(window.windowIdentifier) "
          + "title=\u{201C}\(title)\u{201D} bounds=\(window.bounds.debugDescription)")
  }

case "dump":
  let maxDepth = flagValue("--depth", in: arguments).flatMap { Int($0) } ?? 16
  let application = AccessibilityElement(application: targetPID())
  let windows = application.windows
  if windows.isEmpty { failWith("no accessible windows — is Accessibility granted?") }
  var lines: [String] = []
  for window in windows { printTree(window, depth: 0, maxDepth: maxDepth, into: &lines) }
  if let pattern = flagValue("--grep", in: arguments) {
    lines = lines.filter { $0.range(of: pattern, options: [.caseInsensitive, .regularExpression]) != nil }
    if lines.isEmpty { failWith("no line matched /\(pattern)/") }
  }
  print(lines.joined(separator: "\n"))

case "find", "select", "click":
  guard arguments.count > 1, !arguments[1].hasPrefix("--") else {
    failWith("\(command) needs a text argument")
  }
  let needle = arguments[1]
  let processIdentifier = targetPID()
  let application = AccessibilityElement(application: processIdentifier)
  guard let hit = firstDescendant(of: application, matchingText: needle) else {
    failWith("no element labelled \u{201C}\(needle)\u{201D}")
  }
  switch command {
  case "find":
    let frame = hit.frame.map(\.debugDescription) ?? "<no frame>"
    print("\(hit.descriptionLine)  frame=\(frame)")
  case "select":
    guard selectRow(containing: hit) else { failWith("no AXRow ancestor for \u{201C}\(needle)\u{201D}") }
    print("selected row for \u{201C}\(needle)\u{201D}")
  default:
    let running = NSRunningApplication(processIdentifier: processIdentifier)
    guard clickCentre(of: hit, activating: running) else { failWith("element has no frame to click") }
    print("clicked \u{201C}\(needle)\u{201D}")
  }

case "key":
  guard arguments.count > 1 else { failWith("key needs a chord, e.g. cmd+f") }
  NSRunningApplication(processIdentifier: targetPID())?.activate()
  usleep(200_000)
  guard sendChord(arguments[1]) else { failWith("could not parse chord \u{201C}\(arguments[1])\u{201D}") }
  print("sent \(arguments[1])")

case "shot":
  let processIdentifier = targetPID()
  guard let window = pensieveWindows().first(where: { $0.processIdentifier == processIdentifier }) else {
    failWith("no on-screen window for pid \(processIdentifier)")
  }
  let path = flagValue("--out", in: arguments) ?? "pensieve-window.png"
  guard captureWindow(window, to: path) else { failWith("screencapture failed") }
  print("wrote \(path)")

default:
  print(usage)
  exit(2)
}
