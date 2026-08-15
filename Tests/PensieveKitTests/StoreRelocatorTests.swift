import Testing
import Foundation
import SQLiteData
import os
@testable import PensieveKit

private func makeTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("reloc-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// Every refusal names its own reason. A generic failure here would leave the user guessing which
/// of five different mistakes they made.
@Test func preflightRefusesEachBadDestinationSpecifically() throws {
  let source = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: source) }

  #expect(StoreRelocator.preflight(source: source, destination: source)
          == .destinationIsSource)

  let nested = source.appendingPathComponent("Pensieve", isDirectory: true)
  #expect(StoreRelocator.preflight(source: source, destination: nested)
          == .destinationInsideSource)

  let occupied = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: occupied) }
  try Data("x".utf8).write(to: occupied.appendingPathComponent("something.txt"))
  #expect(StoreRelocator.preflight(source: source, destination: occupied)
          == .destinationNotEmpty)

  // A destination that does not exist yet is fine — the panel's "New Folder" produces exactly this.
  let fresh = try makeTemporaryDirectory().appendingPathComponent("Pensieve", isDirectory: true)
  #expect(StoreRelocator.preflight(source: source, destination: fresh) == nil)
}

/// Builds a realistic source: a canonical store with a known event count, a spool, and a
/// disposable index that must travel with the root. Inserts a real Event (not just a Node) so the
/// event-count verification the relocator performs actually discriminates a good copy from a bad
/// one — a Node-only fixture would make that check vacuously 0 == 0.
private func makePopulatedSource() throws -> URL {
  let source = try makeTemporaryDirectory()
  let database = try openCanonicalDatabase(at: PensievePaths.canonicalURL(in: source))
  let node = Node(name: "N")
  let sourceRecord = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let event = Event(nodeID: node.id, sourceID: sourceRecord.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { sourceRecord }.execute(database)
    try Event.insert { event }.execute(database)
  }
  _ = try CaptureSpool(at: PensievePaths.captureURL(in: source))
  try Data("index".utf8).write(to: source.appendingPathComponent("search-index.sqlite"))
  return source
}

@Test func relocationMovesVerifiesCommitsAndRecycles() async throws {
  let source = try makePopulatedSource()
  let destination = try makeTemporaryDirectory()
    .appendingPathComponent("Pensieve", isDirectory: true)
  let anchor = FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
  let defaults = UserDefaults(suiteName: "relocation-test-\(UUID().uuidString)")!
  defer {
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: anchor)
  }

  let recycled = OSAllocatedUnfairLock(initialState: false)
  let report = try await StoreRelocator(
    source: source, destination: destination, anchor: anchor, defaults: defaults,
    recycle: { _ in recycled.withLock { $0 = true }; return true }
  ).run(progress: { _ in })

  // Everything travelled, including the disposable index — leaving it behind is the silent
  // retrieval outage this feature is most likely to reintroduce.
  #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("pensieve.sqlite").path))
  #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("capture.sqlite").path))
  #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("search-index.sqlite").path))

  // The commit point wrote the key, and the old folder went to the Bin rather than being unlinked.
  #expect(defaults.string(forKey: PensieveDefaults.customSupportRootKey) == destination.path)
  #expect(recycled.withLock { $0 } == true)
  #expect(report.oldFolderRecycled == true)
  #expect(report.movedBytes > 0)
}

/// The commit point is the ONLY point of no return. A failure before it must leave the defaults
/// key unwritten and the source intact, so the user's install is exactly as it was.
@Test func aFailedVerificationLeavesNothingCommitted() async throws {
  let source = try makePopulatedSource()
  let destination = try makeTemporaryDirectory()
    .appendingPathComponent("Pensieve", isDirectory: true)
  let anchor = FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
  let defaults = UserDefaults(suiteName: "relocation-test-\(UUID().uuidString)")!
  defer {
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: anchor)
  }

  var relocator = StoreRelocator(
    source: source, destination: destination, anchor: anchor, defaults: defaults,
    recycle: { _ in Issue.record("must not recycle after a failed verification"); return false })
  // Corrupt the copy between the copy and the verification.
  relocator.corruptCopyForTesting = true

  await #expect(throws: RelocationError.self) {
    _ = try await relocator.run(progress: { _ in })
  }

  #expect(defaults.string(forKey: PensieveDefaults.customSupportRootKey) == nil)
  #expect(FileManager.default.fileExists(atPath: PensievePaths.canonicalURL(in: source).path))
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

/// The reason the verified-move story was chosen over the cheaper one: a git hook that fires
/// during the copy writes to the OLD spool, and that row must still arrive.
@Test func aRowWrittenDuringTheWindowIsRecovered() async throws {
  let source = try makePopulatedSource()
  let destination = try makeTemporaryDirectory()
    .appendingPathComponent("Pensieve", isDirectory: true)
  let anchor = FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
  let defaults = UserDefaults(suiteName: "relocation-test-\(UUID().uuidString)")!
  defer {
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: anchor)
  }

  var relocator = StoreRelocator(
    source: source, destination: destination, anchor: anchor, defaults: defaults,
    recycle: { _ in true })
  // Simulates the hook: append to the OLD spool after the copy, before the flip. Uses a real
  // GitCommitPayload shape (repoPath/hash/branch) so the ingester actually decodes and creates
  // an event — the brief's placeholder `{"sha":"deadbeef"}` doesn't match `GitCommitPayload`'s
  // required keys and would silently fail to decode, leaving the row un-recovered.
  relocator.afterCopyForTesting = { oldSource in
    let spool = try CaptureSpool(at: PensievePaths.captureURL(in: oldSource))
    try spool.append(kind: CaptureKind.gitCommit,
                     payload: #"{"repoPath":"/tmp/reloc-test-repo","hash":"deadbeef","branch":""}"#)
  }

  let report = try await relocator.run(progress: { _ in })
  #expect(report.recoveredRows == 1)
}
