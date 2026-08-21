import Foundation
import PensieveKit
import SQLiteData

@main
enum PensieveSyncAgent {
  static func main() async {
    let home = PensievePaths.homeDirectory()
    // launchd replaces PATH; SyncRunner spawns `/usr/bin/env git` and `claude` which resolve from it.
    setenv("PATH", SyncAgentEnvironment.resolvedPATH(home: home), 1)
    // launchd will not create the log dir.
    try? FileManager.default.createDirectory(
      at: PensievePaths.logsDirectory(), withIntermediateDirectories: true)

    let line: String
    let now = Date().ISO8601Format()
    do {
      let database: any DatabaseWriter
      do {
        database = try openCanonical()
      } catch StoreError.relocationInProgress {
        SyncLog.append("\(now) sync: relocation in progress, skipping\n",
          to: PensievePaths.syncLogURL())
        return
      }
      let syncResult = try await SyncRunner(
        spool: try openSpool(),
        database: database,
        provider: makeDefaultLLMProvider(defaults: PensieveDefaults.shared()),
        projectsDir: PensievePaths.claudeProjectsURL(),
        searchIndexer: .production()).run()
      // The widget must be correct with the app closed, which is most of its life. Quiet by
      // contract: a publish failure must not turn a successful sync into a failed one.
      WidgetDigestPublisher.publishQuietly(database: database)
      line = "\(now) sync: ingested \(syncResult.ingested) event(s), discovered \(syncResult.discovered) session(s), "
        + "extracted \(syncResult.extracted) loose end(s)\n"
    } catch {
      line = "\(now) sync FAILED: \(error)\n"
    }
    // Size-capped append (keeps the mtime moving so `SystemStatus.lastSyncAt` stays honest
    // without a plist `StandardOutPath`, while never letting the file grow unboundedly).
    SyncLog.append(line, to: PensievePaths.syncLogURL())
  }
}
