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
  public func discover(root: URL, recursive: Bool, database: any DatabaseWriter) throws -> [DiscoveryCandidate] {
    var found: [DiscoveredSource] = []
    walk(root, depth: 0, recursive: recursive, into: &found)

    var seen = Set<String>()
    let unique = found.filter { seen.insert("\($0.kind)\u{0}\($0.identityKey)").inserted }

    return try database.read { database in
      try unique.map { source in
        let exists = try Source.where { $0.kind.eq(source.kind) && $0.key.eq(source.identityKey) }.fetchOne(database) != nil
        return DiscoveryCandidate(source: source, alreadyRegistered: exists)
      }
    }
  }

  /// Best-effort per candidate: find-or-create the Source(+Node), then run the type's capture
  /// setup. An onRegister failure (e.g. foreign hooks) is recorded and the Source is kept; the
  /// batch never aborts on it. Rethrows only on a catastrophic DB failure.
  public func accept(_ candidates: [DiscoveredSource], database: any DatabaseWriter) throws -> AcceptResult {
    var result = AcceptResult()
    let resolver = ProjectResolver(database: database)
    for candidate in candidates {
      let existedBefore = try database.read { database in
        try Source.where { $0.kind.eq(candidate.kind) && $0.key.eq(candidate.identityKey) }.fetchOne(database) != nil
      }
      _ = try resolver.resolve(path: candidate.identityKey, kind: candidate.kind)   // find-or-create (own write tx)
      if existedBefore { result.alreadyRegistered.append(candidate) } else { result.registered.append(candidate) }
      if let type = types.first(where: { $0.kind == candidate.kind }) {
        do { try type.onRegister(candidate) } catch { result.setupFailed.append((candidate, String(describing: error))) }
      }
    }
    return result
  }

  private func walk(_ directory: URL, depth: Int, recursive: Bool, into found: inout [DiscoveredSource]) {
    var pruned = false
    for type in types {
      if let detection = type.detect(directory: directory) {
        let normalized = DiscoveredSource(
          kind: detection.kind, directory: Self.normalizedDirectory(detection.directory),
          identityKey: detection.identityKey, displayName: detection.displayName)
        found.append(normalized)
        if type.prunesChildrenWhenDetected { pruned = true }
      }
    }
    if pruned { return }
    guard recursive || depth < 1 else { return }        // non-recursive = root + depth-1

    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    guard let children = try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
    else { return }                                      // unreadable dir → skip, don't abort

    for child in children {
      let vals = try? child.resourceValues(forKeys: keys)
      guard vals?.isDirectory == true, vals?.isSymbolicLink != true else { continue }  // dirs only; never follow symlinks
      if Self.noiseDirs.contains(child.lastPathComponent) { continue }
      walk(Self.normalizedDirectory(child), depth: depth + 1, recursive: recursive, into: &found)
    }
  }

  /// Normalizes a directory URL so two spellings of one directory compare equal — which is what
  /// makes discovered paths match the already-resolved `root`.
  ///
  /// Expressed THROUGH `ProjectResolver.canonical` rather than beside it. This used to be a third
  /// hand-rolled canonicalization (resolve symlinks, then strip a trailing slash by hand) sitting
  /// next to `ProjectResolver.canonical` and `Git.commonDir`'s copy, all three feeding the same
  /// source keys — and a source key that disagrees with itself is two `Source` rows, two `Node`s and
  /// a split project. `URL.path` already drops the trailing slash the hand-rolled version removed,
  /// including for the root, so this is the same rule with one definition.
  private static func normalizedDirectory(_ url: URL) -> URL {
    URL(fileURLWithPath: ProjectResolver.canonical(url.path), isDirectory: false)
  }
}
