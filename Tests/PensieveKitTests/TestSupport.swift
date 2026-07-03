import Foundation
import PensieveKit

/// A unique temp URL for a test database or directory.
/// Pass `ext: nil` for a directory (no extension).
func tempURL(_ prefix: String, ext: String? = "sqlite") -> URL {
  let name = ext.map { "\(prefix)-\(UUID().uuidString).\($0)" } ?? "\(prefix)-\(UUID().uuidString)"
  return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
}

/// Creates a fresh temp git repo with a single commit and returns its path and HEAD hash.
func makeCommittedRepo(message: String = "first commit") throws -> (repo: URL, hash: String) {
  let repo = tempURL("repo", ext: nil)
  try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
  _ = Git.run(["init"], in: repo.path)
  _ = Git.run(["config", "user.email", "t@t.co"], in: repo.path)
  _ = Git.run(["config", "user.name", "T"], in: repo.path)
  try "hello".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
  _ = Git.run(["add", "-A"], in: repo.path)
  _ = Git.run(["commit", "-m", message], in: repo.path)
  let hash = Git.run(["rev-parse", "HEAD"], in: repo.path)!
  return (repo, hash)
}
