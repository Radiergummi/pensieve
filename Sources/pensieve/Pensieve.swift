import ArgumentParser
import Foundation
import PensieveKit

@main
struct Pensieve: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pensieve",
    abstract: "Track work across parallel projects.",
    subcommands: [CaptureCommit.self, CaptureCheckout.self]
  )
}

/// Opens the spool at the standard location (override for tests via PENSIEVE_CAPTURE_DB).
func openSpool() throws -> CaptureSpool {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_CAPTURE_DB"] {
    return try CaptureSpool(at: URL(fileURLWithPath: override))
  }
  return try CaptureSpool(at: PensievePaths.captureURL())
}
