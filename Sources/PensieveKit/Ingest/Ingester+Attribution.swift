import Foundation

/// How a captured row becomes an identity key, and how a row that cannot become one is classified.
///
/// Split out of `Ingester.swift` because these two things are one subject — "which project does this
/// capture belong to, and what does it mean when we cannot say" — and because that subject is where
/// the phantom-project defect lived.
extension Ingester {
  enum IngestError: Error {
    case unattributableSession

    /// Undecodable payload. PERMANENT: the spooled text is immutable, so every future attempt
    /// fails identically.
    case undecodablePayload(kind: String, reason: String)

    /// A git-hook payload whose repo directory is gone AND which carries no capture-time
    /// `commonDir` — a row written before that field existed. Transient by CHOICE: inventing a
    /// node keyed on the dead path is the phantom-project defect, and dropping the row would lose a
    /// real commit. Rows captured by a current CLI cannot reach this.
    case repoDirectoryGone(path: String)

    /// A git identity key that is a catch-all location, not an area of work. PERMANENT.
    case degenerateRepoRoot(key: String)

    /// Whether re-attempting could ever succeed. Drives what `drain` SAYS about the row, not (yet)
    /// what it does with it: a permanent failure logged exactly like a transient one is what made
    /// one malformed payload indistinguishable from a repo that happened to be busy.
    var isPermanent: Bool {
      switch self {
      case .undecodablePayload, .degenerateRepoRoot: return true
      case .unattributableSession, .repoDirectoryGone: return false
      }
    }
  }

  /// The identity key for a payload that came from a git hook — the one place that decides what a
  /// missing common-dir means.
  ///
  /// Prefers the value resolved at CAPTURE time, where the directory was guaranteed to exist,
  /// canonicalized so it is spelled exactly like a freshly resolved key (`ProjectResolver`
  /// canonicalizes on the way in too, so the two cannot diverge into two `Source` rows). Falls back
  /// to asking git now, which only old rows need.
  ///
  /// If both fail it THROWS rather than inventing a key: a git hook only runs inside a repository,
  /// so here a nil common-dir cannot mean "not a repo" — it means the directory is gone. The old
  /// `?? ProjectResolver.canonical(path)` conflated the two and minted a phantom `Source`+`Node` on
  /// the dead path: 9 phantom nodes holding ~42 events belonging to one repo, and 42 of 198 sources
  /// keyed on something that is not a `.git` common-dir. The raw-path fallback survives only for
  /// `SourceKind.claudeCode`, where a non-git cwd is legitimate.
  static func identityKey(forHookPath path: String, capturedCommonDir: String?) throws -> String {
    let key: String
    if let capturedCommonDir, !capturedCommonDir.isEmpty {
      key = ProjectResolver.canonical(capturedCommonDir)
    } else if let resolved = ProjectResolver.identityKey(forRepoPath: path) {
      key = resolved
    } else {
      throw IngestError.repoDirectoryGone(path: path)
    }
    // One guard for both git kinds rather than a copy at each `resolve` call site. A repo's common
    // dir is normally `…/repo/.git`, so this is a backstop against a pathological captured value —
    // but it is the backstop that keeps a node literally named "/" from ever being created again.
    guard !ProjectResolver.isDegenerateRoot(key) else {
      throw IngestError.degenerateRepoRoot(key: key)
    }
    return key
  }
}
