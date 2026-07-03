import ArgumentParser
import PensieveKit

struct Ingest: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ingest",
    abstract: "Drain the capture spool into events, then extract loose ends.")
  func run() async throws {
    let db = try openCanonical()
    let created = try Ingester(spool: try openSpool(), db: db).drain()
    let results = try await ExtractionRunner(db: db, provider: makeDefaultLLMProvider()).run()
    let proposed = results.reduce(0) { $0 + $1.proposed }
    let verified = results.reduce(0) { $0 + $1.verified }
    let inserted = results.reduce(0) { $0 + $1.inserted }
    print("ingested \(created) event(s)")
    print("extraction: \(results.count) session(s) — proposed \(proposed), verified \(verified), inserted \(inserted)")
  }
}
