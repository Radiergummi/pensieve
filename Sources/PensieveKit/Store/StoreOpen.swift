import Foundation
import SQLiteData

/// Opens the spool at the resolved location (override for tests via PENSIEVE_CAPTURE_DB).
/// Takes NO lock: this is the capture path, and it must never block or gain a way to fail.
public func openSpool() throws -> CaptureSpool {
  try CaptureSpool(at: resolvedSpoolURL())
}

/// Opens the canonical store at the resolved location (override for tests via PENSIEVE_DB).
public func openCanonical() throws -> any DatabaseWriter {
  try openCanonicalDatabase(at: resolvedCanonicalURL())
}

/// The resolved spool path: PENSIEVE_CAPTURE_DB > custom support root > default.
public func resolvedSpoolURL() -> URL {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_CAPTURE_DB"] {
    return URL(fileURLWithPath: override)
  }
  return PensievePaths.captureURL()
}

/// The resolved canonical path: PENSIEVE_DB > custom support root > default.
public func resolvedCanonicalURL() -> URL {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_DB"] {
    return URL(fileURLWithPath: override)
  }
  return PensievePaths.canonicalURL()
}
