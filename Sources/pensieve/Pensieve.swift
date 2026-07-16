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
      InstallHooks.self, LooseEnds.self, CheckpointCommand.self, Next.self, Digest.self,
      CaptureSessionStart.self, CaptureSessionEnd.self, InstallSessionHook.self,
      AddNode.self, Nest.self, RenameNode.self, RetypeNode.self, Scan.self,
      Sync.self, LabelSuggest.self, Prime.self, Mcp.self, Eval.self,
    ]
  )
}

/// Opens the canonical store strictly read-only (no migrator, cannot create the file).
/// Override for tests via PENSIEVE_DB. For read-only surfaces: `prime`, `mcp`.
func openCanonicalReadOnly() throws -> any DatabaseReader {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_DB"] {
    return try openCanonicalDatabaseReadOnly(at: URL(fileURLWithPath: override))
  }
  return try openCanonicalDatabaseReadOnly(at: PensievePaths.canonicalURL())
}
