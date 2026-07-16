import Foundation

/// The bounded `sync.log` writer. One ISO-timestamped summary line per sync cycle — a heartbeat
/// file, not a diagnostics log (those go to `os.Logger`). It exists because (a) its **mtime** feeds
/// `SystemStatus.lastSyncAt` as a cheap cross-process "last sync ran" signal, and (b) the unified
/// log's retention is system-controlled (info-level isn't even persisted by default), so a durable
/// history needs a file we own. The cap keeps it from growing unboundedly: past `cap` bytes the file
/// is rewritten with its newest half, cut on a line boundary. At ~25 KB/day of cycles the default
/// 1 MB cap holds roughly 40 days before the first trim.
public enum SyncLog {
  public static let defaultCap = 1_048_576  // 1 MB

  public static func append(_ line: String, to url: URL, cap: Int = defaultCap) {
    let data = Data(line.utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url)
    }
    trimIfNeeded(url: url, cap: cap)
  }

  /// Rewrite the file with its newest `cap / 2` bytes, advanced to the next line boundary so the
  /// head is never a partial line. Best-effort like the append — a failed trim only means the file
  /// stays big until the next cycle.
  private static func trimIfNeeded(url: URL, cap: Int) {
    // Stat via FileManager — URL.resourceValues caches per NSURL and can report a stale size
    // for a file this process just appended to.
    guard cap > 0,
          let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = (attrs[.size] as? NSNumber)?.intValue, size > cap,
          let data = try? Data(contentsOf: url) else { return }
    var start = data.count - cap / 2
    if let newline = data[start...].firstIndex(of: UInt8(ascii: "\n")), newline + 1 < data.count {
      start = newline + 1
    }
    try? data[start...].write(to: url, options: .atomic)
  }
}
