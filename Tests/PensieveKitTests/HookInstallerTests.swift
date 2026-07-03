import Foundation
import Testing
@testable import PensieveKit

@Test func installsExecutableHooks() throws {
  let repo = tempURL("hookrepo", ext: nil)
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

@Test func refusesToOverwriteForeignHook() throws {
  let repo = tempURL("hookrepo", ext: nil)
  let hooksDir = repo.appendingPathComponent(".git/hooks")
  try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

  let custom = "#!/bin/sh\necho custom"
  let postCommit = hooksDir.appendingPathComponent("post-commit")
  try custom.write(to: postCommit, atomically: true, encoding: .utf8)

  #expect(throws: HookInstallError.self) {
    _ = try HookInstaller.install(inRepo: repo)
  }
  // Foreign hook left untouched, not destroyed.
  let onDisk = try String(contentsOf: postCommit, encoding: .utf8)
  #expect(onDisk == custom)
}
