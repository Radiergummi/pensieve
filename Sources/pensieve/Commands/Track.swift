import ArgumentParser
import Foundation
import PensieveKit

struct Track: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "track",
    abstract: "Explicitly register a repo as a project.")
  @Argument var path: String
  func run() throws {
    let absolutePath = URL(fileURLWithPath: path).path
    // Key by the git common-dir, exactly as `GitSource.detect` and the ingester do. Keying by the
    // worktree root instead made `…/repo` and `…/repo/.git` two sources, two nodes, and two list
    // entries for one repo — and a commit captured later landed in a different node than the one
    // this command printed. Refusing a non-repo is deliberate: this command's whole job is
    // registering a repo, and inventing a node under a key no git hook will ever produce is the
    // failure mode, not a convenience.
    guard let key = ProjectResolver.identityKey(forRepoPath: absolutePath) else {
      throw ValidationError("Not a git repository: \(absolutePath)")
    }
    let result = try ProjectResolver(database: try openCanonical())
      .resolve(path: key, kind: SourceKind.gitRepo)
    print("tracking \(result.project.name)")
  }
}
