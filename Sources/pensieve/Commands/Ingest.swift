import ArgumentParser
import PensieveKit

struct Ingest: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ingest",
    abstract: "Drain the capture spool into events, then extract loose ends.")
  func run() async throws {
    let database = try openCanonical()
    // One provider for both passes: the factory reads defaults and can spawn, and building it twice
    // in one command was two answers to a question with one answer.
    let provider = makeDefaultLLMProvider(defaults: PensieveDefaults.shared())
    let created = try await Ingester(spool: try openSpool(), database: database, llm: provider).drain()
    print("ingested \(created) event(s)")
    do {
      let results = try await ExtractionRunner(database: database, provider: provider).run()
      let proposed = results.reduce(0) { $0 + $1.proposed }
      let verified = results.reduce(0) { $0 + $1.verified }
      let inserted = results.reduce(0) { $0 + $1.inserted }
      print("extraction: \(results.count) session(s) — proposed \(proposed), verified \(verified), inserted \(inserted)")
    } catch {
      // The drain above is already committed and its count is already reported, so this is a partial
      // success — but a partial success is still a failure to the caller, and printing it to stdout
      // and exiting 0 told every script the whole command had worked.
      throw CommandFailure("extraction step failed: \(error)")
    }
  }
}
