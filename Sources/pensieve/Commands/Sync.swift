import ArgumentParser
import Foundation
import PensieveKit
import SQLiteData

struct Sync: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "sync",
    abstract: "Drain the spool, discover + ingest finished/in-progress sessions, and extract loose ends.")

  func run() async throws {
    let database: any DatabaseWriter
    do {
      database = try openCanonical()
    } catch StoreError.relocationInProgress {
      // Not a failure: exit 0 so the next scheduled run picks the work up.
      print("\(Date().ISO8601Format()) sync: relocation in progress, skipping")
      return
    }
    let summary = try await SyncRunner(
      spool: try openSpool(),
      database: database,
      provider: makeDefaultLLMProvider(defaults: PensieveDefaults.shared()),
      projectsDir: PensievePaths.claudeProjectsURL(),
      searchIndexer: .production()).run()
    // ISO-timestamped so a silent daemon failure can be correlated to a time.
    print("""
      \(Date().ISO8601Format()) sync: ingested \(summary.ingested) event(s), discovered \(summary.discovered) \
      session(s), extracted \(summary.extracted) loose end(s)
      """)
  }
}
