import ArgumentParser
import Foundation
import PensieveKit

struct Sync: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "sync",
    abstract: "Drain the spool, discover + ingest finished/in-progress sessions, and extract loose ends.")

  func run() async throws {
    let summary = try await SyncRunner(
      spool: try openSpool(),
      db: try openCanonical(),
      provider: makeDefaultLLMProvider(defaults: PensieveDefaults.shared()),
      projectsDir: PensievePaths.claudeProjectsURL()).run()
    // ISO-timestamped so a silent daemon failure can be correlated to a time.
    print("\(Date().ISO8601Format()) sync: ingested \(summary.ingested) event(s), discovered \(summary.discovered) session(s), extracted \(summary.extracted) loose end(s)")
  }
}
