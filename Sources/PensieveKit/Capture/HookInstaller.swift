import Foundation

public enum HookInstallError: Error, CustomStringConvertible {
  case existingHooks([URL])
  case hooksPathRedirected(repo: String, configured: String)

  public var description: String {
    switch self {
    case .existingHooks(let urls):
      let list = urls.map(\.path).joined(separator: ", ")
      return "Refusing to overwrite existing non-Pensieve git hook(s): \(list). Remove them first, then re-run."
    case .hooksPathRedirected(let repo, let configured):
      return """
        core.hooksPath is set to "\(configured)" for \(repo), so git runs hooks from there and \
        ignores .git/hooks entirely. Installing there would have reported success while capturing \
        nothing. Either unset it (git config --unset core.hooksPath, or --global) or add Pensieve's \
        capture-commit / capture-checkout calls to the hooks in "\(configured)" by hand.
        """
    }
  }
}

public enum HookInstaller {
  static let marker = "pensieve-managed-hook"

  // Backgrounded (&) and error-swallowed so a missing/slow `pensieve` never affects git.
  public static func postCommitScript(pensievePath: String) -> String { """
    #!/bin/sh
    # \(Self.marker)
    "\(pensievePath)" capture-commit \
      --repo "$(git rev-parse --show-toplevel)" \
      --hash "$(git rev-parse HEAD)" \
      --branch "$(git rev-parse --abbrev-ref HEAD)" >/dev/null 2>&1 &
    exit 0
    """
  }

  public static func postCheckoutScript(pensievePath: String) -> String { """
    #!/bin/sh
    # \(Self.marker)
    # Only branch checkouts ($3 == 1), not file checkouts.
    [ "$3" = "1" ] || exit 0
    "\(pensievePath)" capture-checkout \
      --repo "$(git rev-parse --show-toplevel)" \
      --from "$1" --to "$2" \
      --branch "$(git rev-parse --abbrev-ref HEAD)" >/dev/null 2>&1 &
    exit 0
    """
  }

  /// The effective `core.hooksPath` for this repo, or nil when unset.
  ///
  /// Set anywhere in git's config cascade — repo-local, `--global`, or system — this redirects git
  /// away from `.git/hooks` completely. Nothing in Pensieve knew about it, so on such a machine
  /// `install` wrote two perfectly good hooks that git would never run and then reported the repo as
  /// set up: capture silently produced nothing, forever, with a success message behind it.
  ///
  /// `git config --get` exits non-zero when the key is unset, which `Git.run` already reports as nil.
  public static func configuredHooksPath(inRepo repo: URL) -> String? {
    guard let value = Git.run(["config", "--get", "core.hooksPath"], in: repo.path),
          !value.isEmpty else { return nil }
    return value
  }

  public static func install(inRepo repo: URL, pensievePath: String = "pensieve") throws -> [URL] {
    // Refuse rather than install into the redirected directory: a `--global` hooksPath is shared by
    // every repo on the machine, so writing there would silently rewrite hooks for projects the user
    // never asked Pensieve to touch. Refusing surfaces honestly — `SourceScanner.accept` records an
    // `onRegister` throw as `setupFailed` and keeps the batch going.
    if let configured = configuredHooksPath(inRepo: repo) {
      throw HookInstallError.hooksPathRedirected(repo: repo.path, configured: configured)
    }
    let hooksDir = repo.appendingPathComponent(".git/hooks", isDirectory: true)
    try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
    let hooks = [("post-commit", postCommitScript(pensievePath: pensievePath)),
                 ("post-checkout", postCheckoutScript(pensievePath: pensievePath))]

    // Refuse to clobber foreign hooks: an existing file that isn't a readable Pensieve-managed
    // hook is treated as a conflict — including one we can't read (permissions/encoding), so an
    // unreadable foreign hook is never silently overwritten.
    var conflicts: [URL] = []
    for (name, _) in hooks {
      let url = hooksDir.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      let isOurs = (try? String(contentsOf: url, encoding: .utf8))?.contains(marker) == true
      if !isOurs { conflicts.append(url) }
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
