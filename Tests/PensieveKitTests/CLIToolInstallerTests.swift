import Testing
import Foundation
@testable import PensieveKit

private func tmpDir() -> URL {
  let d = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
  try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
  return d
}

@Test func bundledCLIURLAppendsContentsHelpers() {
  let u = CLIToolInstaller.bundledCLIURL(appBundleURL: URL(fileURLWithPath: "/Applications/Pensieve.app"))
  #expect(u.path == "/Applications/Pensieve.app/Contents/Helpers/pensieve")
}

@Test func planIsCreateWhenAbsent() {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("pensieve")
  #expect(CLIToolInstaller.plan(linkPath: link, desiredTarget: URL(fileURLWithPath: "/t")) == .create)
}

@Test func planIsUpToDateWhenSymlinkPointsAtTarget() throws {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("pensieve")
  let target = URL(fileURLWithPath: "/Applications/Pensieve.app/Contents/Helpers/pensieve")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  #expect(CLIToolInstaller.plan(linkPath: link, desiredTarget: target) == .upToDate)
}

@Test func planIsRepointWhenSymlinkPointsElsewhere() throws {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("pensieve")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/some/other/pensieve"))
  let target = URL(fileURLWithPath: "/Applications/Pensieve.app/Contents/Helpers/pensieve")
  #expect(CLIToolInstaller.plan(linkPath: link, desiredTarget: target) == .repoint)
}

@Test func planIsBlockedWhenRealFilePresent() throws {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("pensieve")
  try Data("binary".utf8).write(to: link)
  #expect(CLIToolInstaller.plan(linkPath: link, desiredTarget: URL(fileURLWithPath: "/t")) == .blockedRealFile)
}

@Test func applyCreateMakesSymlinkAndParentDir() throws {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("nested/bin/pensieve")  // parent dirs don't exist yet
  let target = dir.appendingPathComponent("Contents/Helpers/pensieve")
  try CLIToolInstaller.apply(.create, linkPath: link, desiredTarget: target)
  #expect((try FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path)
}

@Test func applyRepointReplacesStaleSymlink() throws {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("pensieve")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/old"))
  let target = URL(fileURLWithPath: "/new/pensieve")
  try CLIToolInstaller.apply(.repoint, linkPath: link, desiredTarget: target)
  #expect((try FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path)
}

@Test func applyIsNoOpForBlockedRealFile() throws {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("pensieve")
  try Data("binary".utf8).write(to: link)
  try CLIToolInstaller.apply(.blockedRealFile, linkPath: link, desiredTarget: URL(fileURLWithPath: "/t"))
  // still a regular file, untouched
  let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
  #expect((attrs[.type] as? FileAttributeType) == .typeRegular)
}

@Test func replaceSwapsRealFileForSymlink() throws {
  let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
  let link = dir.appendingPathComponent("pensieve")
  try Data("binary".utf8).write(to: link)
  let target = URL(fileURLWithPath: "/new/pensieve")
  try CLIToolInstaller.replace(linkPath: link, desiredTarget: target)
  #expect((try FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path)
}
