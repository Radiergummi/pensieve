import Foundation
import SQLiteData

/// A filesystem-backed source discovered by inspecting a directory. Pure data — no DB state.
public struct DiscoveredSource: Equatable, Sendable {
  public let kind: String          // a SourceKind constant (e.g. gitRepo)
  public let directory: URL        // the source's main directory (git: the working tree holding .git/)
  public let identityKey: String   // canonicalized; becomes Source.key (git: canonicalized common-dir)
  public let displayName: String   // listing/UI only — accept ignores it (resolve names the node)
  public init(kind: String, directory: URL, identityKey: String, displayName: String) {
    self.kind = kind; self.directory = directory
    self.identityKey = identityKey; self.displayName = displayName
  }
}

/// A discovered source plus whether it is already registered in the canonical store.
public struct DiscoveryCandidate: Equatable, Sendable {
  public let source: DiscoveredSource
  public let alreadyRegistered: Bool
  public init(source: DiscoveredSource, alreadyRegistered: Bool) {
    self.source = source; self.alreadyRegistered = alreadyRegistered
  }
}

/// How to discover and set up one kind of filesystem-backed source. The scanner holds a registry
/// of these and stays kind-agnostic; all git specifics live in `GitSource`.
public protocol FileSystemSourceType: Sendable {
  var kind: String { get }
  /// Policy (not a law): whether the walk skips a detected source's interior. git: true.
  var prunesChildrenWhenDetected: Bool { get }
  /// Detect a source rooted at `directory`. Performs no persistence writes; may touch the
  /// filesystem / shell out to git. Returns nil when there is no source of this kind here.
  func detect(directory: URL) -> DiscoveredSource?
  /// Capture-setup side effects for an accepted source (git: install hooks). No DB access —
  /// `accept` owns the canonical write.
  func onRegister(_ discovered: DiscoveredSource) throws
}
