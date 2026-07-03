import ArgumentParser
import Foundation
import PensieveKit
import SQLiteData

@main
struct Pensieve: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pensieve",
    abstract: "Track work across parallel projects.",
    subcommands: [
      CaptureCommit.self, CaptureCheckout.self, IngestSession.self,
      Ingest.self, ListProjects.self, Status.self, Track.self, Group.self,
      InstallHooks.self, LooseEnds.self, Checkpoint.self,
    ]
  )
}

/// Opens the spool at the standard location (override for tests via PENSIEVE_CAPTURE_DB).
func openSpool() throws -> CaptureSpool {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_CAPTURE_DB"] {
    return try CaptureSpool(at: URL(fileURLWithPath: override))
  }
  return try CaptureSpool(at: PensievePaths.captureURL())
}

/// Opens the canonical store at the standard location (override for tests via PENSIEVE_DB).
func openCanonical() throws -> any DatabaseWriter {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_DB"] {
    return try openCanonicalDatabase(at: URL(fileURLWithPath: override))
  }
  return try openCanonicalDatabase(at: PensievePaths.canonicalURL())
}
