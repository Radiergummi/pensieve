import Foundation

public enum HookInstallError: Error, CustomStringConvertible {
  case existingHooks([URL])

  public var description: String {
    switch self {
    case .existingHooks(let urls):
      let list = urls.map(\.path).joined(separator: ", ")
      return "Refusing to overwrite existing non-Pensieve git hook(s): \(list). Remove them first, then re-run."
    }
  }
}

public enum HookInstaller {
  static let marker = "pensieve-managed-hook"

  // Backgrounded (&) and error-swallowed so a missing/slow `pensieve` never affects git.
  public static let postCommitScript = """
    #!/bin/sh
    # \(Self.marker)
    pensieve capture-commit \
      --repo "$(git rev-parse --show-toplevel)" \
      --hash "$(git rev-parse HEAD)" \
      --branch "$(git rev-parse --abbrev-ref HEAD)" >/dev/null 2>&1 &
    exit 0
    """

  public static let postCheckoutScript = """
    #!/bin/sh
    # \(Self.marker)
    # Only branch checkouts ($3 == 1), not file checkouts.
    [ "$3" = "1" ] || exit 0
    pensieve capture-checkout \
      --repo "$(git rev-parse --show-toplevel)" \
      --from "$1" --to "$2" \
      --branch "$(git rev-parse --abbrev-ref HEAD)" >/dev/null 2>&1 &
    exit 0
    """

  public static func install(inRepo repo: URL) throws -> [URL] {
    let hooksDir = repo.appendingPathComponent(".git/hooks", isDirectory: true)
    try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
    let hooks = [("post-commit", postCommitScript), ("post-checkout", postCheckoutScript)]

    // Refuse to clobber foreign hooks: an existing file without our marker is user-owned.
    var conflicts: [URL] = []
    for (name, _) in hooks {
      let url = hooksDir.appendingPathComponent(name)
      if let existing = try? String(contentsOf: url, encoding: .utf8), !existing.contains(marker) {
        conflicts.append(url)
      }
    }
    guard conflicts.isEmpty else { throw HookInstallError.existingHooks(conflicts) }

    var written: [URL] = []
    for (name, script) in hooks {
      let url = hooksDir.appendingPathComponent(name)
      try script.write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
      written.append(url)
    }
    return written
  }
}
