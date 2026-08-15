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

/// I2: byte sizes must match file-by-file, not just in total — a truncated NON-canonical,
/// non-spool file (the disposable search index, here) must fail verification too, even though
/// neither the event-count check nor the spool reopen would ever touch it.
@Test func aTruncatedNonCanonicalFileFailsVerification() async throws {
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
  // Truncate the copied search index in place — neither the canonical event count nor the spool
  // reopen ever looks at this file, so only a per-file byte-size comparison can catch it.
  relocator.afterCopyForTesting = { _ in
    try Data("i".utf8).write(to: destination.appendingPathComponent("search-index.sqlite"))
  }

  await expectVerificationFailed {
    _ = try await relocator.run(progress: { _ in })
  }

  #expect(defaults.string(forKey: PensieveDefaults.customSupportRootKey) == nil)
  #expect(FileManager.default.fileExists(atPath: PensievePaths.canonicalURL(in: source).path))
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}
