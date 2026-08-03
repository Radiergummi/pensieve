import Foundation
import SQLiteData

public struct AcceptResult: Sendable {
  public var registered: [DiscoveredSource] = []
  public var alreadyRegistered: [DiscoveredSource] = []
  public var setupFailed: [(DiscoveredSource, String)] = []
  public init() {}
}

public struct SourceScanner {
  let types: [any FileSystemSourceType]
  public init(types: [any FileSystemSourceType]) { self.types = types }

  static let noiseDirs: Set<String> = ["node_modules", ".build", ".git", "vendor", "Pods", "DerivedData"]

  /// Write-free: walks `root`, detects sources, dedups by (kind, identityKey), and annotates
  /// whether each is already registered (read-only DB query). Never follows directory symlinks;
  /// skips unreadable directories rather than aborting.
  public func discover(root: URL, recursive: Bool, db: any DatabaseWriter) throws -> [DiscoveryCandidate] {
    var found: [DiscoveredSource] = []
    walk(root, depth: 0, recursive: recursive, into: &found)

    var seen = Set<String>()
    let unique = found.filter { seen.insert("\($0.kind)\u{0}\($0.identityKey)").inserted }

    return try db.read { db in
      try unique.map { s in
        let exists = try Source.where { $0.kind.eq(s.kind) && $0.key.eq(s.identityKey) }.fetchOne(db) != nil
        return DiscoveryCandidate(source: s, alreadyRegistered: exists)
      }
    }
  }

  /// Best-effort per candidate: find-or-create the Source(+Node), then run the type's capture
  /// setup. An onRegister failure (e.g. foreign hooks) is recorded and the Source is kept; the
  /// batch never aborts on it. Rethrows only on a catastrophic DB failure.
  public func accept(_ candidates: [DiscoveredSource], db: any DatabaseWriter) throws -> AcceptResult {
    var result = AcceptResult()
    let resolver = ProjectResolver(db: db)
    for c in candidates {
      let existedBefore = try db.read { db in
        try Source.where { $0.kind.eq(c.kind) && $0.key.eq(c.identityKey) }.fetchOne(db) != nil
      }
      _ = try resolver.resolve(path: c.identityKey, kind: c.kind)   // find-or-create (own write tx)
      if existedBefore { result.alreadyRegistered.append(c) } else { result.registered.append(c) }
      if let type = types.first(where: { $0.kind == c.kind }) {
        do { try type.onRegister(c) } catch { result.setupFailed.append((c, String(describing: error))) }
      }
    }
    return result
  }

  private func walk(_ dir: URL, depth: Int, recursive: Bool, into found: inout [DiscoveredSource]) {
    var pruned = false
    for type in types {
      if let d = type.detect(directory: dir) {
        let normalized = DiscoveredSource(
          kind: d.kind, directory: Self.normalizedDirectory(d.directory),
          identityKey: d.identityKey, displayName: d.displayName)
        found.append(normalized)
        if type.prunesChildrenWhenDetected { pruned = true }
      }
    }
    if pruned { return }
    guard recursive || depth < 1 else { return }        // non-recursive = root + depth-1

    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    guard let children = try? FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
    else { return }                                      // unreadable dir → skip, don't abort

    for child in children {
      let vals = try? child.resourceValues(forKeys: keys)
      guard vals?.isDirectory == true, vals?.isSymbolicLink != true else { continue }  // dirs only; never follow symlinks
      if Self.noiseDirs.contains(child.lastPathComponent) { continue }
      walk(Self.normalizedDirectory(child), depth: depth + 1, recursive: recursive, into: &found)
    }
  }

  /// Resolves symlinks and strips a trailing slash so directory URLs compare equal regardless of
  /// spelling. On macOS `resolvingSymlinksInPath` maps `/private/var…` → `/var…` (and leaves
  /// `/var…` unchanged) — this is what makes discovered paths match the already-resolved `root`.
  private static func normalizedDirectory(_ url: URL) -> URL {
    var path = url.resolvingSymlinksInPath().path
    if path.hasSuffix("/") && path != "/" { path.removeLast() }
    return URL(fileURLWithPath: path, isDirectory: false)
  }
}
