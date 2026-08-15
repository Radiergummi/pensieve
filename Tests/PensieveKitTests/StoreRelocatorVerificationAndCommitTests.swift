import Testing
import Foundation
@testable import PensieveKit

/// The final whole-branch review's fix-wave tests (I1 and I2), split into their own file so
/// `StoreRelocatorTests.swift` stays under the repo's 400-line lint cap — `makeTemporaryDirectory`,
/// `makePopulatedSource`, `removeSuiteDefaults` and `expectVerificationFailed` are shared from
/// there (declared `internal`, not `private`, for exactly this reason).

/// I1: reverting TO Default must CLEAR the key, not persist the default's own absolute path —
/// otherwise `isCustomSupportRoot` reads "Custom" forever after a successful revert, and picking
/// Default a second time resolves `currentRoot == destination` and is refused as
/// `.destinationIsSource`, permanently stranding the picker on "Custom" with no way back except
/// `defaults delete`. A SIBLING of `relocationMovesVerifiesCommitsAndRecycles`, not an edit to it
/// — that test pins the ordinary custom-move behaviour and must keep doing so.
///
/// `defaultDestination` is injected to exactly this test's own temp `destination` — this must
/// NEVER be exercised against the real `PensievePaths.defaultSupportDirectory()`, which is the
/// developer's actual, live, 185-project support folder.
@Test func revertingToDefaultClearsTheKeyInsteadOfWritingIt() async throws {
  let source = try makePopulatedSource()
  let destinationParent = try makeTemporaryDirectory()
  let destination = destinationParent.appendingPathComponent("Pensieve", isDirectory: true)
  let anchor = FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
  let suiteName = "relocation-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  // Pre-seed the key as though a custom root were already active — this is the state a revert
  // actually starts from.
  defaults.set("/some/previous/custom/root", forKey: PensieveDefaults.customSupportRootKey)
  defer {
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: destinationParent)
    try? FileManager.default.removeItem(at: anchor)
    removeSuiteDefaults(defaults, named: suiteName)
  }

  let report = try await StoreRelocator(
    source: source, destination: destination, anchor: anchor, defaults: defaults,
    defaultDestination: destination,
    recycle: { _ in true }
  ).run(progress: { _ in })

  #expect(defaults.object(forKey: PensieveDefaults.customSupportRootKey) == nil)
  #expect(report.oldFolderRecycled == true)
}

/// I2, retargeted by the false-rejection fix wave: the per-file byte-size check is now scoped to
/// `pensieve.sqlite`/`-wal`/`-shm` ONLY (see `StoreRelocator.verifyCopy`'s doc comment) — those are
/// the only files the exclusive lock actually quiesces, so they're the only ones a size mismatch
/// can mean something is wrong. This test used to truncate `search-index.sqlite`, a file the fix
/// deliberately stops checking — left there, it would now pass by NOT failing (the exact vacuous-
/// test failure this project has shipped twice), so it's retargeted at `pensieve.sqlite` itself: a
/// growth there (something neither the event-count reopen nor the spool reopen would necessarily
/// catch, e.g. a `passages`/`loose_ends` row appended past the tracked page count while `events`
/// still matches) must still fail verification.
@Test func aSizeMismatchInTheCanonicalStoreFileItselfFailsVerification() async throws {
  let source = try makePopulatedSource()
  let destinationParent = try makeTemporaryDirectory()
  let destination = destinationParent.appendingPathComponent("Pensieve", isDirectory: true)
  let anchor = FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
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
  // Append trailing bytes to the COPIED `pensieve.sqlite` — SQLite tracks the database's real
  // extent from its own header, so the existing pages (and hence the event count and every
  // existing row) stay perfectly readable; only the file's byte size grows relative to the
  // pre-copy source snapshot. That isolates this test to the byte-size check specifically: the
  // event-count check and the spool reopen (which now run FIRST) both still succeed.
  relocator.afterCopyForTesting = { _ in
    let canonicalDestination = PensievePaths.canonicalURL(in: destination)
    let existing = try Data(contentsOf: canonicalDestination)
    try (existing + Data("extra".utf8)).write(to: canonicalDestination)
  }

  await expectVerificationFailed {
    _ = try await relocator.run(progress: { _ in })
  }

  #expect(defaults.string(forKey: PensieveDefaults.customSupportRootKey) == nil)
  #expect(FileManager.default.fileExists(atPath: PensievePaths.canonicalURL(in: source).path))
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

/// The false rejection this whole fix wave closes: `copyItem` is not atomic — it reads each file
/// as its enumerator reaches it — so a capture hook firing during the copy window legitimately
/// grows the source's `capture.sqlite`/`-wal` mid-copy, with nothing lost anywhere. Reproducing
/// that exact race deterministically isn't possible with the seams this type exposes —
/// `afterCopyForTesting` fires only AFTER `performCopy` already returned (see `run()`), too late to
/// land a write while `copyItem` is still reading. What IS reproducible with that seam, and
/// observably identical to the race's end state, is growing the COPIED spool after the copy: the
/// destination's `capture.sqlite`/`-wal` then differs in size from the T0 snapshot taken before the
/// copy, exactly as a real race would leave it. Under the OLD whole-tree comparison this would have
/// been a `verificationFailed` (`capture.sqlite`/`-wal` sizes recorded at T0 no longer matching the
/// grown copy); under the fix, the spool is out of scope entirely, so it must not affect the result.
@Test func aSpoolThatGrewAfterTheCopyNoLongerFailsVerification() async throws {
  let source = try makePopulatedSource()
  let destinationParent = try makeTemporaryDirectory()
  let destination = destinationParent.appendingPathComponent("Pensieve", isDirectory: true)
  let anchor = FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
  let suiteName = "relocation-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer {
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: destinationParent)
    try? FileManager.default.removeItem(at: anchor)
    removeSuiteDefaults(defaults, named: suiteName)
  }

  var relocator = StoreRelocator(
    source: source, destination: destination, anchor: anchor,
    defaults: defaults, recycle: { _ in true })
  relocator.afterCopyForTesting = { _ in
    let copiedSpool = try CaptureSpool(at: PensievePaths.captureURL(in: destination))
    // A large payload, not a single small row — the file already has enough free space within its
    // existing allocated pages to absorb one small insert without growing at all (measured: a
    // single ~90-byte row left `capture.sqlite`'s byte size UNCHANGED), which would make this test
    // pass vacuously regardless of scoping. This forces genuine page growth.
    let largePayload = String(repeating: "x", count: 32_768)
    try copiedSpool.append(kind: CaptureKind.gitCommit, payload: largePayload)
  }

  _ = try await relocator.run(progress: { _ in })

  #expect(defaults.string(forKey: PensieveDefaults.customSupportRootKey) == destination.path)
  #expect(FileManager.default.fileExists(atPath: destination.path))
}
