import Foundation

public enum Git {
  public static func run(_ arguments: [String], in repo: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", repo] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    guard let output = String(bytes: data, encoding: .utf8) else { return nil }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public extension Git {
  /// The repo-identity directory that unifies all worktrees of one repo. `--git-common-dir`
  /// returns the *main* repo's `.git` even from a linked worktree. nil when `path` is not a repo.
  static func commonDir(in repo: String) -> String? {
    guard let raw = run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repo)
    else { return nil }
    return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
  }

  /// Best-effort default branch: origin/HEAD → init.defaultBranch → probe main/master → "main".
  static func defaultBranch(in repo: String) -> String {
    if let symbolicRef = run(["symbolic-ref", "refs/remotes/origin/HEAD"], in: repo) {
      // e.g. "refs/remotes/origin/release/prod" → "release/prod". Strip the known prefix rather than
      // splitting on "/", which would truncate a slash-containing default branch to its last segment.
      let prefix = "refs/remotes/origin/"
      let name = symbolicRef.hasPrefix(prefix) ? String(symbolicRef.dropFirst(prefix.count)) : symbolicRef
      if !name.isEmpty { return name }
    }
    if let configured = run(["config", "init.defaultBranch"], in: repo), !configured.isEmpty {
      return configured
    }
    if run(["rev-parse", "--verify", "--quiet", "refs/heads/main"], in: repo) != nil { return "main" }
    if run(["rev-parse", "--verify", "--quiet", "refs/heads/master"], in: repo) != nil { return "master" }
    return "main"
  }

  /// Pure decision: the branch key worth tagging on an event, or nil for default/detached/empty.
  static func strandBranchKey(branch: String, defaultBranch: String) -> String? {
    let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedBranch.isEmpty || trimmedBranch == "HEAD" || trimmedBranch == defaultBranch { return nil }
    return trimmedBranch
  }
}
