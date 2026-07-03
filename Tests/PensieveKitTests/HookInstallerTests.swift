import Foundation
import Testing
@testable import PensieveKit

@Test func installsExecutableHooks() throws {
  let repo = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("hookrepo-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: repo.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)

  let written = try HookInstaller.install(inRepo: repo)
  #expect(written.count == 2)

  let postCommit = repo.appendingPathComponent(".git/hooks/post-commit")
  let body = try String(contentsOf: postCommit, encoding: .utf8)
  #expect(body.contains("pensieve capture-commit"))
  let perms = try FileManager.default.attributesOfItem(atPath: postCommit.path)[.posixPermissions] as! NSNumber
  #expect(perms.intValue & 0o111 != 0)   // executable bit set
}
