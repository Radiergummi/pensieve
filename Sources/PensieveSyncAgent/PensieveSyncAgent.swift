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

    let logURL = PensievePaths.syncLogURL()
    let now = Date().ISO8601Format()

    // Logged BEFORE the work, so the log distinguishes "hung mid-pass" from "never ran". Every
    // other line in this file is written after the await, which meant a hang left a log whose last
    // entry was a clean success from hours earlier.
    SyncLog.append("\(now) sync: start\n", to: logURL)

    // Wall-clock watchdog. launchd will not start a second instance while one is running, so a
    // hang here does not merely fail a pass — it stops all background ingestion until logout.
    //
    // It has to TERMINATE the process rather than unwind: a task group awaits its children on exit,
    // so racing the work against a timeout inside one would still block on a genuinely stuck child
    // (a model call that never returns is not guaranteed to observe cancellation). Exiting non-zero
    // is what lets launchd start a healthy instance at the next interval.
    let watchdog = Task.detached {
      try? await Task.sleep(for: .seconds(BackgroundSyncSchedule.passWatchdog))
      guard !Task.isCancelled else { return }
      SyncLog.append("""
        \(Date().ISO8601Format()) sync FAILED: watchdog — pass exceeded \
        \(Int(BackgroundSyncSchedule.passWatchdog))s, terminating so the next pass can run\n
        """, to: logURL)
      exit(75)   // EX_TEMPFAIL — a transient failure, not a bad invocation.
    }
    defer { watchdog.cancel() }

    let line: String
    do {
      let database: any DatabaseWriter
      do {
        database = try openCanonical()
      } catch StoreError.relocationInProgress {
        SyncLog.append("\(now) sync: relocation in progress, skipping\n", to: logURL)
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
    SyncLog.append(line, to: logURL)
  }
}
