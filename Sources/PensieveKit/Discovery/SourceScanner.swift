import Foundation
import SQLiteData

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

  private func walk(_ dir: URL, depth: Int, recursive: Bool, into found: inout [DiscoveredSource]) {
    var pruned = false
    for type in types {
      if let d = type.detect(directory: dir) {
        // Normalize directory path to resolve symlinks (e.g., /var → /private/var on macOS)
        // and strip any trailing slashes for consistent comparison
        var path = d.directory.resolvingSymlinksInPath().path
        if path.hasSuffix("/") && path != "/" {
          path.removeLast()
        }
        let normalized = DiscoveredSource(
          kind: d.kind,
          directory: URL(fileURLWithPath: path, isDirectory: false),
          identityKey: d.identityKey,
          displayName: d.displayName
        )
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
      // Normalize child URL paths to ensure symlinks are resolved consistently throughout the walk
      var childPath = child.resolvingSymlinksInPath().path
      if childPath.hasSuffix("/") && childPath != "/" {
        childPath.removeLast()
      }
      let normalizedChild = URL(fileURLWithPath: childPath, isDirectory: false)
      walk(normalizedChild, depth: depth + 1, recursive: recursive, into: &found)
    }
  }
}
