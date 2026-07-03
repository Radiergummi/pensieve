import Foundation

public enum HookInstaller {
  // Backgrounded (&) and error-swallowed so a missing/slow `pensieve` never affects git.
  public static let postCommitScript = """
    #!/bin/sh
    pensieve capture-commit \
      --repo "$(git rev-parse --show-toplevel)" \
      --hash "$(git rev-parse HEAD)" \
      --branch "$(git rev-parse --abbrev-ref HEAD)" >/dev/null 2>&1 &
    exit 0
    """

  public static let postCheckoutScript = """
    #!/bin/sh
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
    var written: [URL] = []
    for (name, script) in [("post-commit", postCommitScript), ("post-checkout", postCheckoutScript)] {
      let url = hooksDir.appendingPathComponent(name)
      try script.write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
      written.append(url)
    }
    return written
  }
}
