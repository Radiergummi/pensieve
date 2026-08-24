import ArgumentParser
import PensieveKit

struct CaptureCommit: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "capture-commit")
  @Option var repo: String
  @Option var hash: String
  @Option var branch: String

  func run() {
    // Resolve the repo-identity key HERE, not at drain: the hook runs immediately after the commit,
    // so the directory is guaranteed to exist. By the time the ingester sees this row the worktree
    // may be deleted, and asking git then returns nil — which the drain used to paper over with the
    // raw path, minting a phantom project per dead worktree. Same precedent as
    // `capture-session-start`. This adds one `git rev-parse` to a process the hook has already
    // fully detached (`&`, output to /dev/null, `exit 0`), so it cannot delay or fail the commit —
    // verified end to end: an 8 s, exit-3 stand-in CLI left `git commit` at baseline and exit 0.
    let payload = GitCommitPayload(repoPath: repo, hash: hash, branch: branch,
                                   commonDir: ProjectResolver.identityKey(forRepoPath: repo))
    appendCapture(kind: CaptureKind.gitCommit, encoding: payload)
  }
}
