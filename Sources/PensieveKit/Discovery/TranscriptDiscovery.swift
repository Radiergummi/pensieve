import Foundation

/// Pure discovery of Claude Code session transcripts to ingest this cycle. No DB access — the
/// caller injects `alreadyIngested`. Filters (cheapest first): already-an-event (no file read),
/// 0-byte, out-of-window (mtime), and subagent/sidechain transcripts.
public enum TranscriptDiscovery {
  public static func discover(projectsDir: URL, now: Date,
                              ageBound: TimeInterval = 7 * 24 * 60 * 60,
                              alreadyIngested: (String) -> Bool) -> [URL] {
    let fm = FileManager.default
    guard let projectDirs = try? fm.contentsOfDirectory(
      at: projectsDir, includingPropertiesForKeys: nil) else { return [] }

    var out: [URL] = []
    for dir in projectDirs {
      guard let files = try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
      for file in files where file.pathExtension == "jsonl" {
        let sessionID = file.deletingPathExtension().lastPathComponent
        if alreadyIngested(sessionID) { continue }                       // cost guard: no read
        let vals = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if (vals?.fileSize ?? 0) == 0 { continue }                       // not yet populated
        if let mtime = vals?.contentModificationDate,
           now.timeIntervalSince(mtime) > ageBound { continue }          // too old to re-glob
        if isSidechainTranscript(file) { continue }                      // subagent -> precision gate
        out.append(file)
      }
    }
    return out
  }

  /// True if any record in the transcript is flagged `isSidechain: true` (a Claude Code
  /// subagent/Task transcript). Defensive/future-proofing: current Claude Code stores subagent
  /// transcripts outside `~/.claude/projects`, so this matches 0 real files today — but it keeps
  /// agent-internal prose out of the loose-end extractor (the make-or-break precision gate) if
  /// that changes. Only reads files that survived the cheaper filters (i.e. new sessions), so a
  /// given transcript is read at most until it becomes an event.
  static func isSidechainTranscript(_ url: URL) -> Bool {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      if (obj["isSidechain"] as? Bool) == true { return true }
    }
    return false
  }
}
