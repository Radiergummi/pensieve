import Foundation
import SQLiteData
import os

public enum RelocationError: Error, Equatable {
  case lockUnavailable
  case destinationNotWritable
  case destinationInsideSource
  case destinationIsSource
  case destinationNotEmpty
  case destinationAlreadyExists
  case destinationNotADirectory
  case insufficientSpace(needed: Int64, available: Int64)
  case verificationFailed(String)
}

/// Copies the support directory to a new location, verifies the copy against the source's event
/// count, and only THEN commits by writing the custom-support-root default — the single point of
/// no return. Every step before the commit point leaves the defaults key unwritten, the
/// destination cleaned up, and the source intact; every step after is best-effort (recovering a
/// row a hook wrote to the old spool during the copy window, recycling the old folder) and is
/// reported back rather than silently swallowed.
public struct StoreRelocator {
  public struct Report: Sendable {
    public let movedBytes: Int64
    public let recoveredRows: Int
    public let oldFolderRecycled: Bool
    /// True when a row may still be sitting un-migrated in the OLD spool after the commit —
    /// either the old spool or the new store could not be reopened, or `Ingester.drain()` left a
    /// row unmarked (it threw). When true, STEP 7 never recycles: losing that folder to the Trash
    /// with no signal would be worse than leaving it for a manual look.
    public let recoveryIncomplete: Bool
  }

  let source: URL
  let destination: URL
  let anchor: URL
  let defaults: UserDefaults
  /// What counts as "the default" at the commit point (see `run()`, STEP 5). Injectable for the
  /// same reason `anchor` and `defaults` are: a test asserting the revert-to-default behaviour
  /// must NEVER be exercised against the real `PensievePaths.defaultSupportDirectory()`, which is
  /// the developer's actual, live support folder — injecting a temp directory here lets a test
  /// treat ITS destination as "the default" without the comparison ever touching the real path.
  let defaultDestination: URL
  let recycle: @Sendable (URL) -> Bool

  /// Test seams. Both default to inert. They exist because the two properties that matter most —
  /// "a failure before the commit point changes nothing" and "a row written during the window is
  /// recovered" — are otherwise only observable by racing a real filesystem.
  var corruptCopyForTesting = false
  var afterCopyForTesting: (@Sendable (URL) throws -> Void)?

  public init(source: URL, destination: URL,
              anchor: URL = StoreRelocationLock.anchorURL(),
              defaults: UserDefaults = PensieveDefaults.shared(),
              defaultDestination: URL = PensievePaths.defaultSupportDirectory(),
              recycle: @escaping @Sendable (URL) -> Bool) {
    self.source = source; self.destination = destination
    self.anchor = anchor; self.defaults = defaults
    self.defaultDestination = defaultDestination
    self.recycle = recycle
  }

  /// Cheap, pure-ish refusals run before anything is copied, each naming its own reason.
  /// `FileManager.copyItem(at:to:)` throws whenever `to` already exists — in ANY form: a file, an
  /// empty directory, or a non-empty one — so every one of those must be refused here, not just
  /// the occupied-directory case. Directory-ness is read from `fileExists(atPath:isDirectory:)`
  /// directly rather than inferred from a swallowed `contentsOfDirectory` throw, which reports
  /// ENOTDIR on a regular file as "empty" and would let a file slip through as a valid target.
  public static func preflight(source: URL, destination: URL) -> RelocationError? {
    let sourcePath = source.standardizedFileURL.path
    let destinationPath = destination.standardizedFileURL.path

    if destinationPath == sourcePath { return .destinationIsSource }
    // A destination under the source would have the copy write into its own input.
    if destinationPath.hasPrefix(sourcePath + "/") { return .destinationInsideSource }

    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    if manager.fileExists(atPath: destinationPath, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else { return .destinationNotADirectory }
      let contents = (try? manager.contentsOfDirectory(atPath: destinationPath)) ?? []
      return contents.isEmpty ? .destinationAlreadyExists : .destinationNotEmpty
    }
    // Writability is checked on the nearest EXISTING ancestor: the destination itself usually does
    // not exist yet, and `isWritableFile` on a missing path is always false.
    var probe = destination.deletingLastPathComponent()
    while !manager.fileExists(atPath: probe.path), probe.path != "/" {
      probe = probe.deletingLastPathComponent()
    }
    if !manager.isWritableFile(atPath: probe.path) { return .destinationNotWritable }

    return nil
  }

  public func run(progress: @Sendable (Double) -> Void) async throws -> Report {
    if let refusal = Self.preflight(source: source, destination: destination) { throw refusal }

    // STEP 1 — exclusive lock. A sync in flight holds a shared lock and wins; the caller reports
    // "sync running, try again" and boots normally against the old root. `defer { _ = lock }`
    // is NOT a lifetime guarantee (a discarded assignment isn't something the optimizer must
    // honour) — `withExtendedLifetime` is, and this is the one line holding the lock for the
    // entire relocation.
    guard let lock = StoreRelocationLock(at: anchor, exclusive: true) else {
      throw RelocationError.lockUnavailable
    }
    defer { withExtendedLifetime(lock) {} }

    let manager = FileManager.default
    let measuredBytes = Self.directorySize(at: source)
    try Self.checkFreeSpace(needed: measuredBytes, at: destination)

    // Drain the spool into the current canonical store, so as little as possible is in flight.
    let sourceCanonicalURL = PensievePaths.canonicalURL(in: source)
    let sourceSpoolURL = PensievePaths.captureURL(in: source)
    try await drainSourceSpool(canonicalURL: sourceCanonicalURL, spoolURL: sourceSpoolURL, manager: manager)

    // STEP 2 — the count that verification will match against.
    let expectedEvents = try Self.eventCount(at: sourceCanonicalURL)
    progress(0.05)

    // Snapshot the source's per-file sizes right before the copy starts (post-drain, so it
    // reflects what is actually about to be copied) and BEFORE `afterCopyForTesting`/a real hook
    // write can land on the source — a row arriving in the recovery window must never be mistaken
    // for a truncated copy.
    let sourceSizesBeforeCopy = Self.fileSizeMap(at: source)
    try performCopy(manager: manager)
    progress(0.75)

    try? afterCopyForTesting?(source)
    if corruptCopyForTesting {
      try? Data().write(to: PensievePaths.canonicalURL(in: destination))
    }

    try verifyCopy(expectedEvents: expectedEvents, sourceSizes: sourceSizesBeforeCopy, manager: manager)
    progress(0.85)

    // STEP 5 — THE COMMIT POINT. Reverting TO the default clears the key instead of persisting
    // the default's absolute path — otherwise `isCustomSupportRoot` would read "Custom" forever
    // after a successful revert, and picking Default a second time would resolve
    // `currentRoot == destination` and be refused as `.destinationIsSource`, making the picker
    // permanently stuck on "Custom" with no way back except `defaults delete`.
    if destination.standardizedFileURL == defaultDestination.standardizedFileURL {
      defaults.removeObject(forKey: PensieveDefaults.customSupportRootKey)
    } else {
      defaults.set(destination.path, forKey: PensieveDefaults.customSupportRootKey)
    }

    let recovery = await recoverPendingRows(sourceSpoolURL: sourceSpoolURL, manager: manager)
    progress(0.95)

    // STEP 7 — the Bin, not unlink. 130 MB of canonical store stays recoverable if the new
    // location turns out to be wrong — but never recycle when recovery could not be verified
    // complete: the old spool may still hold a row a hook wrote during the copy window, and
    // losing it to the Trash with no signal is worse than an extra manual cleanup.
    let didRecycle = recovery.incomplete ? false : recycle(source)
    progress(1.0)

    Log.sync.info("""
      Relocated store: \(measuredBytes, privacy: .public) bytes, \
      recovered \(recovery.recovered, privacy: .public) row(s), \
      recycled=\(didRecycle, privacy: .public), \
      recoveryIncomplete=\(recovery.incomplete, privacy: .public)
      """)
    return Report(movedBytes: measuredBytes, recoveredRows: recovery.recovered,
                  oldFolderRecycled: didRecycle, recoveryIncomplete: recovery.incomplete)
  }

  /// Drains the spool into the CURRENT canonical store before measuring/copying, so as little as
  /// possible is left in flight during the copy window. Explicitly closes both connections before
  /// returning: `performCopy`'s plain filesystem copy is only correct if the WAL for each store has
  /// already been folded back into its main file, and GRDB documents deinit-driven closing as
  /// "sufficient for most applications" — not a precise guarantee — while this one genuinely needs
  /// precise timing.
  private func drainSourceSpool(canonicalURL: URL, spoolURL: URL, manager: FileManager) async throws {
    guard manager.fileExists(atPath: canonicalURL.path) else { return }
    let database = try openCanonicalDatabase(at: canonicalURL)
    let spool = try CaptureSpool(at: spoolURL)
    _ = try? await Ingester(spool: spool, database: database).drain()
    try database.close()
    try spool.close()
  }

  /// STEP 3 — COPY, not move. `moveItem` across volumes is internally copy-then-delete and can
  /// leave partial state at the destination on failure; moving to another disk is the whole point
  /// of this feature, so the source stays intact until after the commit point.
  private func performCopy(manager: FileManager) throws {
    // Recorded BEFORE the attempt so a failure can never delete a path this run did not create —
    // preflight already refuses every destination that exists beforehand, but this is the last
    // line of defense against a TOCTOU race or a future preflight regression.
    let destinationPreexisted = manager.fileExists(atPath: destination.path)
    do {
      try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                  withIntermediateDirectories: true)
      try manager.copyItem(at: source, to: destination)
    } catch {
      if !destinationPreexisted {
        try? manager.removeItem(at: destination)
      }
      throw error
    }
  }

  /// STEP 4 — semantic verification. Opening the copy and matching the event count catches the
  /// failure that matters most, without hashing 130 MB. The copied SPOOL is verified too — capture
  /// hooks take no lock, so `capture.sqlite`/`-wal` can be copied mid-write, and a torn copy must
  /// not silently become the live capture store the instant the commit lands.
  ///
  /// The per-file byte-size check runs LAST, and is scoped to `pensieve.sqlite`/`-wal`/`-shm`
  /// ONLY — the three files the exclusive lock (STEP 1) actually quiesces: no admitted canonical
  /// writer can coexist with it (`CanonicalWriterGate`/`StoreOpen.swift`), and `drainSourceSpool`
  /// closes its own connections before the copy, so these three are the only files this run can
  /// promise are frozen at snapshot time. Everything else under the support directory —
  /// `capture.sqlite`/`-wal` (capture hooks take NO lock, by design), `narration-cache.sqlite`
  /// (written by concurrent `pensieve mcp` warming, never through the gate), and the disposable
  /// search/translation indexes — can legitimately differ in size across the copy window with
  /// nothing lost, so a whole-tree comparison false-rejected a healthy copy on every one of them.
  /// It runs last, after the event-count and spool-reopen checks, so a SQLite-level failure on the
  /// files it now cares about (a corrupt/truncated `pensieve.sqlite`) surfaces the more specific
  /// error those two already produce; this check is the narrower net behind them, catching what
  /// they don't — a lost WAL tail, or `passages`/`loose_ends` rows dropped while `events` happened
  /// to still match.
  ///
  /// `sourceSizes` is a snapshot taken BEFORE the copy started (see `run()`), not a re-measurement
  /// of the source taken now — a row a hook legitimately wrote to the source's spool during the
  /// copy window (recovered separately in STEP 6) would otherwise make an honest copy look
  /// "truncated" by comparison to a source that has since grown. `copyItem` itself is not atomic —
  /// it reads each file as its enumerator reaches it — so even a canonical-store file legitimately
  /// reflects the source somewhere INSIDE the copy window, not at the exact snapshot instant; the
  /// exclusive lock is what makes that a non-issue for these three specific files (nothing else can
  /// be writing them), not the snapshot timing.
  private func verifyCopy(expectedEvents: Int, sourceSizes: [String: Int64], manager: FileManager) throws {
    do {
      let copiedEvents = try Self.eventCount(at: PensievePaths.canonicalURL(in: destination))
      guard copiedEvents == expectedEvents else {
        throw RelocationError.verificationFailed(
          "event count \(copiedEvents) != \(expectedEvents)")
      }
      _ = try CaptureSpool.readOnlyStats(at: PensievePaths.captureURL(in: destination))

      let destinationSizes = Self.fileSizeMap(at: destination)
      if let message = Self.canonicalStoreSizeMismatchMessage(source: sourceSizes, destination: destinationSizes) {
        throw RelocationError.verificationFailed(message)
      }
    } catch {
      try? manager.removeItem(at: destination)
      throw error is RelocationError ? error
        : RelocationError.verificationFailed(String(describing: error))
    }
  }

  /// The only files the exclusive lock genuinely quiesces (see `verifyCopy`'s doc comment).
  /// Derived from `PensievePaths.canonicalStoreFileName` rather than spelled out, so renaming the
  /// store file cannot leave relocation copying and verifying a name that no longer exists.
  private static let canonicalStoreFileNames = [
    PensievePaths.canonicalStoreFileName,
    "\(PensievePaths.canonicalStoreFileName)-wal",
    "\(PensievePaths.canonicalStoreFileName)-shm",
  ]

  /// Scoped, not whole-tree: only `canonicalStoreFileNames`. A name absent from BOTH sides (a
  /// fresh install may have no `-wal`/`-shm` yet) is fine; present on one side only, or differing
  /// in size, is a mismatch — the message names the exact file and both byte counts instead of
  /// just counting paths.
  private static func canonicalStoreSizeMismatchMessage(
    source: [String: Int64], destination: [String: Int64]
  ) -> String? {
    for name in canonicalStoreFileNames {
      let sourceSize = source[name]
      let destinationSize = destination[name]
      guard sourceSize != destinationSize else { continue }
      let sourceDescription = sourceSize.map(String.init) ?? "absent"
      let destinationDescription = destinationSize.map(String.init) ?? "absent"
      return "canonical store file size differs: \(name) — source \(sourceDescription), "
        + "destination \(destinationDescription)"
    }
    return nil
  }

  /// STEP 6 — close the window: rows a hook wrote to the OLD spool during 3–5 still arrive.
  /// Returns how many were recovered AND whether recovery is known-complete. A `try?` failure
  /// anywhere here must never collapse to "0 recovered, all clear" — that reads as "nothing was
  /// pending" and would let STEP 7 recycle a folder that may still hold un-migrated rows.
  private func recoverPendingRows(sourceSpoolURL: URL, manager: FileManager)
    async -> (recovered: Int, incomplete: Bool) {
    guard manager.fileExists(atPath: sourceSpoolURL.path) else { return (0, false) }
    guard let oldSpool = try? CaptureSpool(at: sourceSpoolURL) else { return (0, true) }
    guard let newDatabase = try? openCanonicalDatabase(at: PensievePaths.canonicalURL(in: destination))
    else { return (0, true) }
    guard let recovered = try? await Ingester(spool: oldSpool, database: newDatabase).drain()
    else { return (0, true) }
    // A row `drain()` could not ingest (e.g. it threw) is left unmarked rather than counted — an
    // unreadable count is treated as "still incomplete", not as "clear", for the same reason.
    let stillPending = (try? oldSpool.pendingCount()) ?? 1
    return (recovered, stillPending != 0)
  }

  /// Uses a READ-ONLY, non-migrating open for both the source's pre-copy count and the copy's
  /// post-copy count. `openCanonicalDatabase` would `ensureParentDirectory` and CREATE the file
  /// (running the full migrator) if it were missing — against the source that mutates a store the
  /// spec requires stay intact on any pre-commit failure; against the destination it would let a
  /// copy that produced no canonical file at all "verify" clean whenever `expectedEvents == 0` (a
  /// fresh install relocated before first capture), since the verifier would just create an empty
  /// store and compare 0 == 0. A read-only open cannot create the file, so a failure to open IS the
  /// "copy is missing" signal.
  private static func eventCount(at url: URL) throws -> Int {
    let database = try openCanonicalDatabaseReadOnly(at: url)
    let count = try database.read { database in try Event.fetchCount(database) }
    try database.close()
    return count
  }

  public static func directorySize(at url: URL) -> Int64 {
    fileSizeMap(at: url).values.reduce(0, +)
  }

  /// Every file under `url`, keyed by its path RELATIVE to `url` so a source tree and a copied
  /// destination tree (different absolute roots, same layout) compare directly. Shares one
  /// enumerator with `directorySize` rather than walking the tree twice — two near-identical
  /// filesystem walks drifting apart is the exact defect class this project keeps getting bitten
  /// by (`SearchHitResolver`, the loose-end `isOpen` filter).
  static func fileSizeMap(at url: URL) -> [String: Int64] {
    guard let enumerator = FileManager.default.enumerator(
      at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return [:] }
    let rootPath = url.standardizedFileURL.path
    var sizes: [String: Int64] = [:]
    for case let fileURL as URL in enumerator {
      let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      let standardizedPath = fileURL.standardizedFileURL.path
      let relativePath = standardizedPath.hasPrefix(rootPath + "/")
        ? String(standardizedPath.dropFirst(rootPath.count + 1))
        : standardizedPath
      sizes[relativePath] = Int64(size)
    }
    return sizes
  }

  static func checkFreeSpace(needed: Int64, at destination: URL) throws {
    var probe = destination
    while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
      probe = probe.deletingLastPathComponent()
    }
    let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    // A nil reading means "could not determine" and must not block a relocation; a reading of ZERO
    // means the volume is genuinely full. `?? 0` collapsed the two, so the `available == 0` clause —
    // written as the undeterminable escape hatch — also whitelisted a completely full destination,
    // which is the one case this check exists to catch.
    guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
    guard available >= needed else {
      throw RelocationError.insufficientSpace(needed: needed, available: available)
    }
  }
}
