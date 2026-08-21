import CoreGraphics
import Cocoa

let pensieveBundleIdentifier = "me.mazetti.pensieve"

struct PensieveWindow {
  let processIdentifier: pid_t
  let windowIdentifier: CGWindowID
  let title: String
  let bounds: CGRect
}

/// On-screen windows belonging to Pensieve processes.
///
/// An empty `title` is meaningful: macOS redacts `kCGWindowName` when Screen Recording is not
/// granted, so a window listed with no title is the signal that the grant is missing — which is why
/// such windows are returned rather than filtered out.
func pensieveWindows() -> [PensieveWindow] {
  let pensieveProcessIdentifiers = Set(
    NSRunningApplication.runningApplications(withBundleIdentifier: pensieveBundleIdentifier)
      .map(\.processIdentifier)
  )
  let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
  guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    return []
  }
  return raw.compactMap { entry in
    guard let processIdentifier = entry[kCGWindowOwnerPID as String] as? pid_t,
          pensieveProcessIdentifiers.contains(processIdentifier),
          let windowIdentifier = entry[kCGWindowNumber as String] as? CGWindowID else { return nil }
    var bounds = CGRect.zero
    if let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Any] {
      bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) ?? .zero
    }
    return PensieveWindow(
      processIdentifier: processIdentifier,
      windowIdentifier: windowIdentifier,
      title: entry[kCGWindowName as String] as? String ?? "",
      bounds: bounds
    )
  }
}

/// Why a target process could not be resolved. A named type rather than `Result<pid_t, String>`,
/// which the plan specified and which does not compile — `String` does not conform to `Error`, and
/// the alternative (a retroactive `extension String: Error`) would inflict that conformance on
/// every string in the tool.
struct TargetProcessResolutionError: Error {
  let message: String
}

/// Resolves which Pensieve process to target. A fixture-backed instance and the live app share a
/// bundle identifier, so an ambiguous target is an error rather than a coin flip.
func resolveTargetProcess(explicit: pid_t?) -> Result<pid_t, TargetProcessResolutionError> {
  if let explicit { return .success(explicit) }
  let running = NSRunningApplication.runningApplications(withBundleIdentifier: pensieveBundleIdentifier)
  switch running.count {
  case 0: return .failure(TargetProcessResolutionError(message: "Pensieve is not running"))
  case 1: return .success(running[0].processIdentifier)
  default:
    let processIdentifierList = running.map { String($0.processIdentifier) }.joined(separator: ", ")
    return .failure(TargetProcessResolutionError(
      message: "\(running.count) Pensieve instances running (pids: \(processIdentifierList)) — pass --pid"))
  }
}
