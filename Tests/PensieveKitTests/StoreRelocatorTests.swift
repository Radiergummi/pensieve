import Testing
import Foundation
import SQLiteData
import os
@testable import PensieveKit

/// Internal, not private: shared with `StoreRelocatorVerificationAndCommitTests.swift`, the
/// sibling file the I1/I2 fix-wave tests live in (split out to keep this file under the repo's
/// 400-line lint cap).
func makeTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("reloc-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// `removePersistentDomain(forName:)` alone does NOT delete the backing plist file — verified
/// directly: it survives even after an explicit `synchronize()`, because cfprefsd's on-disk
/// write-back is asynchronous and not guaranteed to happen before this test process exits.
/// Without also unlinking the file, every test run using a throwaway suite left a fresh
/// `relocation-test-<uuid>.plist` behind in `~/Library/Preferences` regardless of the
/// `removePersistentDomain` call — 51 were found on this machine from prior runs.
func removeSuiteDefaults(_ defaults: UserDefaults, named suiteName: String) {
  defaults.removePersistentDomain(forName: suiteName)
  let path = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Preferences/\(suiteName).plist").path
  try? FileManager.default.removeItem(atPath: path)
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

  // A destination path that does not exist yet is fine.
  let freshParent = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: freshParent) }
  let fresh = freshParent.appendingPathComponent("Pensieve", isDirectory: true)
  #expect(StoreRelocator.preflight(source: source, destination: fresh) == nil)
}

/// `FileManager.copyItem(at:to:)` throws whenever `to` already exists, in ANY form — not just a
/// non-empty directory. An existing EMPTY directory (e.g. one just made via a save panel's
/// "New Folder") and an existing regular file must each be refused too, and each pre-existing path
/// must be left completely untouched by preflight itself (a pure, read-only check).
@Test func preflightRefusesAnExistingEmptyDirectoryAndAnExistingRegularFile() throws {
  let source = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: source) }

  let emptyDirectory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: emptyDirectory) }
  #expect(StoreRelocator.preflight(source: source, destination: emptyDirectory)
          == .destinationAlreadyExists)
  #expect(FileManager.default.fileExists(atPath: emptyDirectory.path))

  let regularFileParent = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: regularFileParent) }
  let regularFile = regularFileParent.appendingPathComponent("Pensieve")
  try Data("not a directory".utf8).write(to: regularFile)
  #expect(StoreRelocator.preflight(source: source, destination: regularFile)
          == .destinationNotADirectory)
  #expect(FileManager.default.fileExists(atPath: regularFile.path))
}

/// Builds a realistic source: a canonical store with a known event count, a spool, and a
/// disposable index that must travel with the root. Inserts a real Event (not just a Node) so the
/// event-count verification the relocator performs actually discriminates a good copy from a bad
/// one — a Node-only fixture would make that check vacuously 0 == 0.
func makePopulatedSource() throws -> URL {
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
  let destinationParent = try makeTemporaryDirectory()
  let destination = destinationParent.appendingPathComponent("Pensieve", isDirectory: true)
  let anchor = FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
  // The domain is removed in the `defer` below — without it, every run of this test leaves a
  // `relocation-test-<uuid>.plist` behind in `~/Library/Preferences` forever (51 found on this
  // machine from prior runs before this fix).
  let suiteName = "relocation-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer {
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: destinationParent)
    try? FileManager.default.removeItem(at: anchor)
    removeSuiteDefaults(defaults, named: suiteName)
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
  #expect(report.recoveryIncomplete == false)
}

/// Asserts `operation` throws `RelocationError.verificationFailed`, ignoring the associated
/// message (which embeds dynamic counts) — pinning the CASE, not just `RelocationError.self`,
/// which any other case (e.g. `.lockUnavailable`) would also satisfy vacuously.
func expectVerificationFailed(_ operation: () async throws -> Void) async {
  do {
    try await operation()
    Issue.record("expected .verificationFailed, but no error was thrown")
  } catch let error as RelocationError {
    guard case .verificationFailed = error else {
      Issue.record("expected .verificationFailed, got \(error)")
      return
    }
  } catch {
    Issue.record("expected RelocationError.verificationFailed, got \(error)")
  }
}

/// The commit point is the ONLY point of no return. A failure before it must leave the defaults
/// key unwritten and the source intact, so the user's install is exactly as it was.
@Test func aFailedVerificationLeavesNothingCommitted() async throws {
  let source = try makePopulatedSource()
  let destinationParent = try makeTemporaryDirectory()
  let destination = destinationParent.appendingPathComponent("Pensieve", isDirectory: true)
  let anchor = FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
  // The domain is removed in the `defer` below — without it, every run of this test leaves a
  // `relocation-test-<uuid>.plist` behind in `~/Library/Preferences` forever (51 found on this
  // machine from prior runs before this fix).
  let suiteName = "relocation-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer {
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: destinationParent)
    try? FileManager.default.removeItem(at: anchor)
    removeSuiteDefaults(defaults, named: suiteName)
  }

  var relocator = StoreRelocator(
    source: source, destination: destination, anchor: anchor, defaults: defaults,
    recycle: { _ in Issue.record("must not recycle after a failed verification"); return false })
  // Corrupt the copy between the copy and the verification.
  relocator.corruptCopyForTesting = true

  await expectVerificationFailed {
    _ = try await relocator.run(progress: { _ in })
  }

  #expect(defaults.string(forKey: PensieveDefaults.customSupportRootKey) == nil)
  #expect(FileManager.default.fileExists(atPath: PensievePaths.canonicalURL(in: source).path))
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

/// Capture hooks take no lock, so `capture.sqlite`/`-wal` can be copied mid-write. A torn/corrupt
/// spool copy must fail verification too — before this fix only the canonical event count was
/// checked, so a corrupt spool would still commit and become the live capture store.
@Test func aCorruptSpoolCopyFailsVerification() async throws {
  let source = try makePopulatedSource()
  let destinationParent = try makeTemporaryDirectory()
  let destination = destinationParent.appendingPathComponent("Pensieve", isDirectory: true)
  let anchor = FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
  // The domain is removed in the `defer` below — without it, every run of this test leaves a
  // `relocation-test-<uuid>.plist` behind in `~/Library/Preferences` forever (51 found on this
  // machine from prior runs before this fix).
  let suiteName = "relocation-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer {
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: destinationParent)
    try? FileManager.default.removeItem(at: anchor)
    removeSuiteDefaults(defaults, named: suiteName)
  }

  var relocator = StoreRelocator(
    source: source, destination: destination, anchor: anchor, defaults: defaults,
    recycle: { _ in Issue.record("must not recycle after a failed verification"); return false })
  relocator.afterCopyForTesting = { _ in
    try Data("not a sqlite file".utf8).write(to: PensievePaths.captureURL(in: destination))
  }

  await expectVerificationFailed {
    _ = try await relocator.run(progress: { _ in })
  }

  #expect(defaults.string(forKey: PensieveDefaults.customSupportRootKey) == nil)
  #expect(FileManager.default.fileExists(atPath: PensievePaths.canonicalURL(in: source).path))
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

/// The false-positive this closes: a fresh install relocated before its first capture has a
/// migrated but EMPTY (0-event) canonical store. If verification ever creates a missing file on
/// demand, a copy that dropped its canonical file entirely would "verify" clean (0 == 0) instead
/// of failing — a missing file must always mean "the copy is missing it", never "zero events".
@Test func aMissingCopiedCanonicalFileFailsVerificationRatherThanVacuouslyMatching() async throws {
  let source = try makeTemporaryDirectory()
  _ = try openCanonicalDatabase(at: PensievePaths.canonicalURL(in: source))   // migrated, 0 events
  _ = try CaptureSpool(at: PensievePaths.captureURL(in: source))
  let destinationParent = try makeTemporaryDirectory()
  let destination = destinationParent.appendingPathComponent("Pensieve", isDirectory: true)
  let anchor = FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
  // The domain is removed in the `defer` below — without it, every run of this test leaves a
  // `relocation-test-<uuid>.plist` behind in `~/Library/Preferences` forever (51 found on this
  // machine from prior runs before this fix).
  let suiteName = "relocation-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer {
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: destinationParent)
    try? FileManager.default.removeItem(at: anchor)
    removeSuiteDefaults(defaults, named: suiteName)
  }

  var relocator = StoreRelocator(
    source: source, destination: destination, anchor: anchor, defaults: defaults,
    recycle: { _ in Issue.record("must not recycle after a failed verification"); return false })
  relocator.afterCopyForTesting = { _ in
    try FileManager.default.removeItem(at: PensievePaths.canonicalURL(in: destination))
  }

  await expectVerificationFailed {
    _ = try await relocator.run(progress: { _ in })
  }

  #expect(defaults.string(forKey: PensieveDefaults.customSupportRootKey) == nil)
  #expect(FileManager.default.fileExists(atPath: PensievePaths.canonicalURL(in: source).path))
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

/// A row `Ingester.drain()` cannot ingest (malformed payload) is left unmarked in the old spool —
/// that must never be silently reported as "0 recovered, all clear", and the old folder must not
/// be recycled while data may still be stranded there.
@Test func anUnrecoverableRowBlocksRecycling() async throws {
  let source = try makePopulatedSource()
  let destinationParent = try makeTemporaryDirectory()
  let destination = destinationParent.appendingPathComponent("Pensieve", isDirectory: true)
  let anchor = FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
  // The domain is removed in the `defer` below — without it, every run of this test leaves a
  // `relocation-test-<uuid>.plist` behind in `~/Library/Preferences` forever (51 found on this
  // machine from prior runs before this fix).
  let suiteName = "relocation-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer {
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: destinationParent)
    try? FileManager.default.removeItem(at: anchor)
    removeSuiteDefaults(defaults, named: suiteName)
  }

  var relocator = StoreRelocator(
    source: source, destination: destination, anchor: anchor, defaults: defaults,
    recycle: { _ in Issue.record("must not recycle when recovery is incomplete"); return true })
  relocator.afterCopyForTesting = { oldSource in
    let spool = try CaptureSpool(at: PensievePaths.captureURL(in: oldSource))
    try spool.append(kind: CaptureKind.gitCommit, payload: "not json")
  }

  let report = try await relocator.run(progress: { _ in })
  #expect(report.recoveryIncomplete == true)
  #expect(report.oldFolderRecycled == false)
}

/// The reason the verified-move story was chosen over the cheaper one: a git hook that fires
/// during the copy writes to the OLD spool, and that row must still arrive.
@Test func aRowWrittenDuringTheWindowIsRecovered() async throws {
  let source = try makePopulatedSource()
  let destinationParent = try makeTemporaryDirectory()
  let destination = destinationParent.appendingPathComponent("Pensieve", isDirectory: true)
  let anchor = FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
  // The domain is removed in the `defer` below — without it, every run of this test leaves a
  // `relocation-test-<uuid>.plist` behind in `~/Library/Preferences` forever (51 found on this
  // machine from prior runs before this fix).
  let suiteName = "relocation-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer {
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: destinationParent)
    try? FileManager.default.removeItem(at: anchor)
    removeSuiteDefaults(defaults, named: suiteName)
  }

  var relocator = StoreRelocator(
    source: source, destination: destination, anchor: anchor, defaults: defaults,
    recycle: { _ in true })
  // Simulates the hook: append to the OLD spool after the copy, before the flip. The payload must
  // name a repo that REALLY EXISTS. It used to point at a fabricated `/tmp/reloc-test-repo`, which
  // only produced an event because the ingester's old identity-key fallback invented a project keyed
  // on that dead path — i.e. this test was passing on the strength of the phantom-project defect.
  // With that fallback gone, a git capture whose directory cannot be resolved stays pending, so the
  // fixture has to be a genuine repo for "the row is recovered" to mean anything.
  let (repo, hash) = try makeCommittedRepo()
  defer { try? FileManager.default.removeItem(at: repo) }
  relocator.afterCopyForTesting = { oldSource in
    let spool = try CaptureSpool(at: PensievePaths.captureURL(in: oldSource))
    try spool.append(kind: CaptureKind.gitCommit,
                     payload: try encodeJSON(GitCommitPayload(
                       repoPath: repo.path, hash: hash, branch: "main",
                       commonDir: ProjectResolver.identityKey(forRepoPath: repo.path))))
  }

  let report = try await relocator.run(progress: { _ in })
  #expect(report.recoveredRows == 1)
  #expect(report.recoveryIncomplete == false)
}
