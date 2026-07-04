import Foundation

/// Git as one concrete filesystem-backed source: a directory whose `.git` is a real directory
/// (a main working tree). Linked worktrees and submodules (whose `.git` is a file) are skipped.
public struct GitSource: FileSystemSourceType {
  public let pensievePath: String
  public init(pensievePath: String) { self.pensievePath = pensievePath }

  public var kind: String { SourceKind.gitRepo }
  public var prunesChildrenWhenDetected: Bool { true }

  public func detect(directory: URL) -> DiscoveredSource? {
    var isDir: ObjCBool = false
    let dotGit = directory.appendingPathComponent(".git").path
    guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir), isDir.boolValue,
          let common = Git.commonDir(in: directory.path)
    else { return nil }
    let identityKey = ProjectResolver.canonical(common)
    return DiscoveredSource(kind: kind, directory: directory, identityKey: identityKey,
                            displayName: ProjectResolver.displayName(forKey: identityKey))
  }

  public func onRegister(_ discovered: DiscoveredSource) throws {
    _ = try HookInstaller.install(inRepo: discovered.directory, pensievePath: pensievePath)
  }
}
