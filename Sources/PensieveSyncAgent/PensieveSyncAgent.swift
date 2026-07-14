import Foundation
import PensieveKit

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
      let s = try await SyncRunner(
        spool: try openSpool(),
        db: try openCanonical(),
        provider: makeDefaultLLMProvider(defaults: PensieveDefaults.shared()),
        projectsDir: PensievePaths.claudeProjectsURL()).run()
      line = "\(now) sync: ingested \(s.ingested) event(s), discovered \(s.discovered) session(s), extracted \(s.extracted) loose end(s)\n"
    } catch {
      line = "\(now) sync FAILED: \(error)\n"
    }
    appendToSyncLog(line)
  }

  /// Append the summary line to sync.log (creating it if absent). This is what keeps the log's
  /// mtime moving so `SystemStatus.lastSyncAt` stays honest without a plist `StandardOutPath`.
  private static func appendToSyncLog(_ line: String) {
    let url = PensievePaths.syncLogURL()
    let data = Data(line.utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url)
    }
  }
}
