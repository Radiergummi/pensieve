import ArgumentParser
import PensieveKit

struct Ingest: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ingest",
    abstract: "Drain the capture spool into events, then extract loose ends.")
  func run() async throws {
    let database = try openCanonical()
    let provider = makeDefaultLLMProvider(defaults: PensieveDefaults.shared())
    let created = try await Ingester(spool: try openSpool(), database: database, llm: provider).drain()
    print("ingested \(created) event(s)")
    do {
      let results = try await ExtractionRunner(database: database, provider: makeDefaultLLMProvider(defaults: PensieveDefaults.shared())).run()
      let proposed = results.reduce(0) { $0 + $1.proposed }
      let verified = results.reduce(0) { $0 + $1.verified }
      let inserted = results.reduce(0) { $0 + $1.inserted }
      print("extraction: \(results.count) session(s) — proposed \(proposed), verified \(verified), inserted \(inserted)")
    } catch {
      print("extraction step failed: \(error)")
    }
  }
}
