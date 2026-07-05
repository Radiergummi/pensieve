import Testing
import Foundation
@testable import PensieveKit

private func makeProjectsDir() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("proj-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root.appendingPathComponent("repoA"),
                                          withIntermediateDirectories: true)
  return root
}

/// Writes a transcript file under <projects>/repoA/<name>.jsonl with the given first-line JSON,
/// then stamps its modification date.
@discardableResult
private func writeTx(_ projects: URL, _ name: String, line: String, mtime: Date) throws -> URL {
  let url = projects.appendingPathComponent("repoA/\(name).jsonl")
  try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
  return url
}

@Test func discoverReturnsOnlyNewNonEmptyInWindowTopLevelTranscripts() throws {
  let projects = try makeProjectsDir()
  let resolvedProjects = projects.resolvingSymlinksInPath()
  let now = Date(timeIntervalSince1970: 1_000_000)
  let cwdLine = #"{"type":"user","cwd":"/x","message":{"role":"user","content":"hi"}}"#

  // (a) already an event -> skipped without reading
  try writeTx(projects, "already", line: cwdLine, mtime: now)
  // (b) fresh, non-empty, in-window, has cwd -> RETURNED
  let wanted = try writeTx(projects, "wanted", line: cwdLine, mtime: now.addingTimeInterval(-60))
  // (c) ancient (older than 7d) -> skipped
  try writeTx(projects, "ancient", line: cwdLine, mtime: now.addingTimeInterval(-8 * 24 * 3600))
  // (d) 0-byte -> skipped
  let zero = projects.appendingPathComponent("repoA/zero.jsonl")
  try "".write(to: zero, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: zero.path)
  // (e) sidechain/subagent -> skipped
  try writeTx(projects, "sidechain",
              line: #"{"type":"user","cwd":"/x","isSidechain":true,"message":{"role":"user","content":"agent"}}"#,
              mtime: now)

  let result = TranscriptDiscovery.discover(projectsDir: resolvedProjects, now: now) { sessionID in
    sessionID == "already"
  }
  #expect(result.map { $0.deletingPathExtension().lastPathComponent } == ["wanted"])
  #expect(result == [wanted.resolvingSymlinksInPath()])
}

@Test func discoverReturnsEmptyForMissingProjectsDir() {
  let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
  #expect(TranscriptDiscovery.discover(projectsDir: missing, now: Date()) { _ in false }.isEmpty)
}
