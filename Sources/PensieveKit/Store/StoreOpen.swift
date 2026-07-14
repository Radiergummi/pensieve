import Foundation
import SQLiteData

/// Opens the spool at the standard location (override for tests via PENSIEVE_CAPTURE_DB).
public func openSpool() throws -> CaptureSpool {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_CAPTURE_DB"] {
    return try CaptureSpool(at: URL(fileURLWithPath: override))
  }
  return try CaptureSpool(at: PensievePaths.captureURL())
}

/// Opens the canonical store at the standard location (override for tests via PENSIEVE_DB).
public func openCanonical() throws -> any DatabaseWriter {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_DB"] {
    return try openCanonicalDatabase(at: URL(fileURLWithPath: override))
  }
  return try openCanonicalDatabase(at: PensievePaths.canonicalURL())
}
