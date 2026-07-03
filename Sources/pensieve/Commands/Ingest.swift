import ArgumentParser
import PensieveKit

struct Ingest: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ingest",
    abstract: "Drain the capture spool into the canonical store.")
  func run() throws {
    let n = try Ingester(spool: try openSpool(), db: try openCanonical()).drain()
    print("ingested \(n) event(s)")
  }
}
