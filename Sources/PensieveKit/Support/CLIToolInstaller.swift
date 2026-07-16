import Foundation

/// Decides and applies the state of the `~/.local/bin/pensieve` symlink that bridges external callers
/// (git hooks, Claude Code hooks, `claude mcp add`) to the CLI bundled inside `Pensieve.app`. Pure
/// Foundation, no app types — the app is a thin caller. Uses `lstat`-style `attributesOfItem` (which
/// does NOT follow symlinks) so a symlink, a broken symlink, and a real file are told apart correctly.
public enum CLIToolInstaller {
  public enum Plan: Equatable {
    case create            // nothing at linkPath → make the symlink
    case upToDate          // already our symlink, correct target → no-op
    case repoint           // a symlink pointing elsewhere → (Settings-only) replace it
    case blockedRealFile   // a regular file / dir lives there → (Settings-only) explicit replace
  }

  /// The bundled CLI's on-disk location for a given `.app` bundle URL.
  public static func bundledCLIURL(appBundleURL: URL) -> URL {
    appBundleURL.appendingPathComponent("Contents/Helpers/pensieve")
  }

  /// Inspect the current filesystem state at `linkPath` and decide the action needed to make it point
  /// at `desiredTarget`. Mutates nothing.
  public static func plan(linkPath: URL, desiredTarget: URL, fileManager: FileManager = .default) -> Plan {
    guard let attrs = try? fileManager.attributesOfItem(atPath: linkPath.path) else {
      return .create   // lstat failed → nothing there
    }
    guard (attrs[.type] as? FileAttributeType) == .typeSymbolicLink else {
      return .blockedRealFile   // a real file/dir — never clobber implicitly
    }
    let stored = (try? fileManager.destinationOfSymbolicLink(atPath: linkPath.path)) ?? ""
    let resolved = stored.hasPrefix("/")
      ? stored
      : linkPath.deletingLastPathComponent().appendingPathComponent(stored).path
    return resolved == desiredTarget.path ? .upToDate : .repoint
  }

  /// Apply the SAFE plans: `.create` / `.repoint` create (or replace a stale symlink with) the link,
  /// creating `~/.local/bin` if needed. `.upToDate` / `.blockedRealFile` are no-ops (callers gate).
  public static func apply(_ plan: Plan, linkPath: URL, desiredTarget: URL, fileManager: FileManager = .default) throws {
    switch plan {
    case .create, .repoint:
      try fileManager.createDirectory(
        at: linkPath.deletingLastPathComponent(), withIntermediateDirectories: true)
      if (try? fileManager.attributesOfItem(atPath: linkPath.path)) != nil {
        try fileManager.removeItem(at: linkPath)   // remove the stale symlink (never its target)
      }
      try fileManager.createSymbolicLink(at: linkPath, withDestinationURL: desiredTarget)
    case .upToDate, .blockedRealFile:
      return
    }
  }

  /// Explicit + destructive: remove WHATEVER is at `linkPath` (incl. a real file) and create the
  /// symlink. Only called from the Settings "Replace existing binary" confirmation — never at launch.
  public static func replace(linkPath: URL, desiredTarget: URL, fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(
      at: linkPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    if (try? fileManager.attributesOfItem(atPath: linkPath.path)) != nil {
      try fileManager.removeItem(at: linkPath)
    }
    try fileManager.createSymbolicLink(at: linkPath, withDestinationURL: desiredTarget)
  }
}
