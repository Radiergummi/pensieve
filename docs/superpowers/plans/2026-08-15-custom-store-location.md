# Custom Store Location Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Pensieve's support folder a user-settable location, changed through a verified move of the existing data, and re-lay-out Settings ▸ Advanced ▸ Store & Logs so paths are legible and selectable.

**Architecture:** Four independent copies of the "check env, else default" path rule collapse into one pure resolver in `PensievePaths`, which grows a middle precedence layer reading a shared-defaults key. Concurrent canonical **writers** are excluded during a move by an advisory `flock` anchored *outside* the moving directory, acquired once per process inside `openCanonical()`. The move itself is a copy-verify-commit-recycle state machine in PensieveKit, executed by the app **at launch, before any store is opened**, so there is nothing to tear down.

**Tech Stack:** Swift 6, SwiftUI, GRDB/SQLiteData, Swift Testing, XcodeGen + Xcode 26.6, String Catalog.

**Spec:** `docs/superpowers/specs/2026-08-15-custom-store-location-design.md`

## Global Constraints

- **No Python, ever. Swift only.**
- **Name things explicitly — no abbreviations, no single letters.** `database`, `node`, `looseEnd`, `event`, `payload` — never `db`, `n`, `le`, `ev`, `p`. Terse names already in the codebase are historical Claude output, not the project's style; do not match them. `identifier_name` must not be relaxed to accommodate anything you write.
- **SwiftLint is enforced in CI (`swiftlint lint --strict`)**, config at `.swiftlint.yml`. Files cap at **400 lines**.
- **SQLiteData 1.6.6 predicates use `.eq(x)`, NOT `== x`.** `==` is `unavailable` and won't compile.
- **The capture path is sacred**: `openSpool()` and every `pensieve capture-*` command must never block, never take a lock, and never gain a new way to fail.
- **The trust gate is untouched** by this work. Do not read, write, or reference `TranscriptVocabulary.injectionMarkers` or `TranscriptParser.isInjectedOrCommand`.
- **Run tests with `make test`** (optionally `FILTER=<name>`). Build the app with `make build`. Full CI-equivalent: `make all`. Never `swift run pensieve` — the CLI is an Xcode tool target (`make cli`).
- **`xcodegen generate` is required** after adding or deleting any app-target source file; the `.xcodeproj` is generated and gitignored. `make build` runs it.
- **No new LLM-backed task is introduced**, so no `EvalTask` registration is required.
- **Localization:** app **chrome** is localized `en` + `de` in `Sources/PensieveApp/Localizable.xcstrings`. **Paths, node names, and quotes are content and are never localized.** `xcodebuild` does **not** auto-populate the catalog — keys are hand-authored, and a mis-keyed `de` value falls back to English silently.
- All line references are against `main` at `f51a51e`.

---

### Task 1: Collapse path resolution into one resolver

The four independent copies of the env-override rule become one. This task adds the defaults layer but wires **no UI** — after it, behaviour is byte-identical to today because no one writes the new key yet.

**Files:**
- Modify: `Sources/PensieveKit/Support/PensieveDefaults.swift`
- Modify: `Sources/PensieveKit/Support/PensievePaths.swift:4-7,40-52`
- Modify: `Sources/PensieveKit/Store/StoreOpen.swift:5-17`
- Modify: `Sources/pensieve/Pensieve.swift:24-29`
- Modify: `Sources/PensieveApp/PensieveApp.swift:6-15` (delete `Stores`)
- Modify: `Sources/PensieveApp/AppModel.swift:221,223,225,241-242`
- Test: `Tests/PensieveKitTests/PensievePathsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `PensieveDefaults.customSupportRootKey: String` — `"customSupportRoot"`
  - `PensievePaths.supportDirectory(customRoot:) -> URL` — pure, `customRoot: String?`
  - `PensievePaths.supportDirectory() -> URL` — reads the world, unchanged signature
  - `PensievePaths.defaultSupportDirectory() -> URL` — the un-overridable `~/Library/Application Support/Pensieve`

- [ ] **Step 1: Write the failing test**

Append to `Tests/PensieveKitTests/PensievePathsTests.swift`:

```swift
/// Precedence is env > defaults > default, and it is a PURE function over injected values.
/// `setenv` is process-global and Swift Testing runs suites in parallel, so the rule is never
/// tested by mutating the real environment — the same reason `indexURL(named:storeOverride:)`
/// was split out at `PensievePaths.swift:44-46`.
@Test func supportDirectoryPrecedenceIsPure() {
  let fallback = PensievePaths.defaultSupportDirectory().path

  // No override: byte-identical to the historical path, so no existing install is orphaned.
  #expect(PensievePaths.supportDirectory(customRoot: nil).path == fallback)

  // A custom root wins over the default.
  #expect(PensievePaths.supportDirectory(customRoot: "/Volumes/Work/Pensieve").path
          == "/Volumes/Work/Pensieve")

  // An empty or whitespace-only stored value is treated as absent, never as "/".
  #expect(PensievePaths.supportDirectory(customRoot: "").path == fallback)
  #expect(PensievePaths.supportDirectory(customRoot: "   ").path == fallback)

  // A relative path is refused — a relative support root would resolve against whatever cwd
  // launchd handed the process (`/`), which is how you get a store at the filesystem root.
  #expect(PensievePaths.supportDirectory(customRoot: "relative/dir").path == fallback)
}

/// Everything derived must follow the custom root, or the install ends up half-relocated —
/// the state the one-root design exists to make unrepresentable.
@Test func derivedPathsFollowTheCustomRoot() {
  let root = "/Volumes/Work/Pensieve"
  let support = PensievePaths.supportDirectory(customRoot: root)

  #expect(PensievePaths.canonicalURL(in: support).path == root + "/pensieve.sqlite")
  #expect(PensievePaths.captureURL(in: support).path == root + "/capture.sqlite")
  #expect(PensievePaths.narrationCacheURL(in: support).path == root + "/narration-cache.sqlite")

  // The disposable indexes follow the root too. This is the regression this feature is most
  // likely to reintroduce: an index left behind in the OLD directory is a silent, total
  // retrieval outage (see PensievePaths.swift:30-35).
  #expect(PensievePaths.indexURL(named: "search-index.sqlite", storeOverride: nil, support: support).path
          == root + "/search-index.sqlite")
  #expect(PensievePaths.indexURL(named: "translation-cache.sqlite", storeOverride: nil, support: support).path
          == root + "/translation-cache.sqlite")

  // PENSIEVE_DB still wins over the custom root, and still keeps its per-store prefix rule,
  // so `make smoke` and every test recipe behave exactly as before.
  #expect(PensievePaths.indexURL(named: "search-index.sqlite",
                                 storeOverride: "/tmp/throwaway.sqlite", support: support).path
          == "/tmp/throwaway-search-index.sqlite")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test FILTER=supportDirectoryPrecedenceIsPure`
Expected: FAIL — compile error, `defaultSupportDirectory` and `supportDirectory(customRoot:)` do not exist.

- [ ] **Step 3: Add the defaults key**

In `Sources/PensieveKit/Support/PensieveDefaults.swift`, beside the existing keys:

```swift
  /// Absolute path of a user-chosen support folder. Absent = the default
  /// `~/Library/Application Support/Pensieve`. Written only by the app's relocator, read by every
  /// process that resolves a Pensieve path.
  public static let customSupportRootKey = "customSupportRoot"
```

- [ ] **Step 4: Write the resolver**

Replace the top of `Sources/PensieveKit/Support/PensievePaths.swift`:

```swift
public enum PensievePaths {
  /// The shared defaults handle, constructed ONCE. `supportDirectory()` runs on every git-hook
  /// capture, and the capture path is sacred — a per-call `UserDefaults(suiteName:)` would put a
  /// domain construction on it for no reason. Reads from a cached cfprefsd domain are microseconds.
  private static let sharedDefaults = PensieveDefaults.shared()

  /// The un-overridable location. Kept separate so the resolver has something to fall back TO and
  /// so tests can name the fallback without restating the string.
  public static func defaultSupportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Pensieve", isDirectory: true)
  }

  /// The rule, pure and injectable. Separated from reading the world for the same reason
  /// `indexURL(named:storeOverride:)` is: the real source is process-global shared state, and
  /// Swift Testing runs suites in parallel.
  ///
  /// A blank or relative stored value is treated as absent rather than honoured. A relative root
  /// would resolve against the process's cwd — `/` under launchd — which is how a store ends up at
  /// the filesystem root.
  public static func supportDirectory(customRoot: String?) -> URL {
    guard let customRoot else { return defaultSupportDirectory() }
    let trimmed = customRoot.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return defaultSupportDirectory() }
    return URL(fileURLWithPath: trimmed, isDirectory: true)
  }

  /// The one call site that reads the world. Never throws; a failed read yields the default.
  public static func supportDirectory() -> URL {
    supportDirectory(customRoot: sharedDefaults.string(forKey: PensieveDefaults.customSupportRootKey))
  }

  public static func canonicalURL(in support: URL) -> URL {
    support.appendingPathComponent("pensieve.sqlite")
  }
  public static func canonicalURL() -> URL { canonicalURL(in: supportDirectory()) }

  public static func captureURL(in support: URL) -> URL {
    support.appendingPathComponent("capture.sqlite")
  }
  public static func captureURL() -> URL { captureURL(in: supportDirectory()) }

  /// The disposable narration cache (shared across app / CLI / MCP). Not the canonical store,
  /// not the spool — losing it costs only a re-narrate.
  public static func narrationCacheURL(in support: URL) -> URL {
    support.appendingPathComponent("narration-cache.sqlite")
  }
  public static func narrationCacheURL() -> URL { narrationCacheURL(in: supportDirectory()) }
```

Then give the two `indexURL` helpers an injectable support directory. Replace `PensievePaths.swift:40-52`:

```swift
  private static func indexURL(named name: String) -> URL {
    indexURL(named: name,
             storeOverride: ProcessInfo.processInfo.environment["PENSIEVE_DB"],
             support: supportDirectory())
  }

  /// The rule itself, separated from reading the environment so it is testable: `setenv` is
  /// process-global and Swift Testing runs suites in parallel, so a test that mutated `PENSIEVE_DB`
  /// to cover this could perturb every other test reading it.
  static func indexURL(named name: String, storeOverride: String?, support: URL) -> URL {
    guard let storeOverride else { return support.appendingPathComponent(name) }
    let store = URL(fileURLWithPath: storeOverride)
    let prefix = store.deletingPathExtension().lastPathComponent
    return store.deletingLastPathComponent().appendingPathComponent("\(prefix)-\(name)")
  }
```

Leave `searchIndexURL()`, `translationCacheURL()`, `llmScratchDirectory()`, `logsDirectory()`, `syncLogURL()`, `launchAgentURL()`, `installedBinaryURL()` and `ensureParentDirectory(of:)` exactly as they are — they already route through `supportDirectory()` or the home directory and now inherit the custom root for free.

- [ ] **Step 5: Fix the pre-existing `indexURL` test for the new parameter**

The existing `indexPathFollowsAnOverriddenStore` test calls the two-argument form. Add the third argument to each of its six calls:

```swift
  #expect(PensievePaths.indexURL(named: "search-index.sqlite", storeOverride: nil,
                                 support: PensievePaths.supportDirectory()).path
          == support + "/search-index.sqlite")
```

...and the same for the other five. Do **not** delete or weaken any of its assertions — it pins the "no override is byte-identical" property this task must not break.

- [ ] **Step 6: Run the path tests**

Run: `make test FILTER=PathsTests`
Expected: PASS — all four tests in the file.

- [ ] **Step 7: Collapse the four call sites**

`Sources/PensieveKit/Store/StoreOpen.swift` — unchanged behaviour, but now the only definition of the rule for stores:

```swift
import Foundation
import SQLiteData

/// Opens the spool at the resolved location (override for tests via PENSIEVE_CAPTURE_DB).
/// Takes NO lock: this is the capture path, and it must never block or gain a way to fail.
public func openSpool() throws -> CaptureSpool {
  try CaptureSpool(at: resolvedSpoolURL())
}

/// Opens the canonical store at the resolved location (override for tests via PENSIEVE_DB).
public func openCanonical() throws -> any DatabaseWriter {
  try openCanonicalDatabase(at: resolvedCanonicalURL())
}

/// The resolved spool path: PENSIEVE_CAPTURE_DB > custom support root > default.
public func resolvedSpoolURL() -> URL {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_CAPTURE_DB"] {
    return URL(fileURLWithPath: override)
  }
  return PensievePaths.captureURL()
}

/// The resolved canonical path: PENSIEVE_DB > custom support root > default.
public func resolvedCanonicalURL() -> URL {
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_DB"] {
    return URL(fileURLWithPath: override)
  }
  return PensievePaths.canonicalURL()
}
```

`Sources/pensieve/Pensieve.swift:24-29` becomes:

```swift
/// Opens the canonical store strictly read-only (no migrator, cannot create the file).
/// For read-only surfaces: `prime`, `mcp`. Takes no lock — readers never block a relocation.
func openCanonicalReadOnly() throws -> any DatabaseReader {
  try openCanonicalDatabaseReadOnly(at: resolvedCanonicalURL())
}
```

`Sources/PensieveApp/PensieveApp.swift:5-15` — **delete the `Stores` enum entirely**. It was the fourth copy.

`Sources/PensieveApp/AppModel.swift` — replace every `Stores.canonicalURL` with `resolvedCanonicalURL()` and every `Stores.spoolURL` with `resolvedSpoolURL()` (five sites: `:221` twice in the log line, `:223`, `:225`, `:241`, `:242`).

- [ ] **Step 8: Verify the whole suite and the app build**

Run: `make test`
Expected: PASS, no regressions (baseline is 753 tests in 16 suites; this task adds 2).

Run: `make build`
Expected: BUILD SUCCEEDED. `Stores` is gone and nothing references it.

- [ ] **Step 9: Commit**

```bash
git add Sources/PensieveKit/Support/PensievePaths.swift \
        Sources/PensieveKit/Support/PensieveDefaults.swift \
        Sources/PensieveKit/Store/StoreOpen.swift \
        Sources/pensieve/Pensieve.swift \
        Sources/PensieveApp/PensieveApp.swift \
        Sources/PensieveApp/AppModel.swift \
        Tests/PensieveKitTests/PensievePathsTests.swift
git commit -m "refactor(kit): one path resolver, with a custom-support-root layer"
```

---

### Task 2: The relocation lock

An advisory `flock` anchored where the moving directory cannot reach it. Standalone and fully tested before anything depends on it.

**Files:**
- Create: `Sources/PensieveKit/Store/StoreRelocationLock.swift`
- Test: `Tests/PensieveKitTests/StoreRelocationLockTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `final class StoreRelocationLock: @unchecked Sendable`
  - `StoreRelocationLock.anchorURL() -> URL` — `~/Library/Caches/me.mazetti.pensieve/relocation.lock`
  - `init?(at url: URL, exclusive: Bool)` — nil when the lock is unavailable
  - `deinit` releases

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/StoreRelocationLockTests.swift`:

```swift
import Testing
import Foundation
@testable import PensieveKit

/// A per-test anchor. The real anchor is `~/Library/Caches/…`, which the test suite must never
/// touch — a test that locked it would block the developer's own running app.
private func temporaryAnchor() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
}

@Test func exclusiveLockExcludesSharedAndExclusive() throws {
  let anchor = temporaryAnchor()
  defer { try? FileManager.default.removeItem(at: anchor) }

  let exclusive = StoreRelocationLock(at: anchor, exclusive: true)
  #expect(exclusive != nil)

  // While the relocator holds it, no writer may open and no second relocation may start.
  #expect(StoreRelocationLock(at: anchor, exclusive: false) == nil)
  #expect(StoreRelocationLock(at: anchor, exclusive: true) == nil)
}

@Test func sharedLocksCoexistButBlockExclusive() throws {
  let anchor = temporaryAnchor()
  defer { try? FileManager.default.removeItem(at: anchor) }

  // Two writers may run concurrently — that is today's behaviour and this must not change it.
  let firstWriter = StoreRelocationLock(at: anchor, exclusive: false)
  let secondWriter = StoreRelocationLock(at: anchor, exclusive: false)
  #expect(firstWriter != nil)
  #expect(secondWriter != nil)

  // But a relocation cannot begin under them.
  #expect(StoreRelocationLock(at: anchor, exclusive: true) == nil)
}

/// The lock must not wedge the system when its holder goes away. `flock` is released by the
/// kernel when the descriptor closes, including on crash — this asserts we did not defeat that
/// by leaking the descriptor somewhere it outlives the object.
@Test func releasingTheLockAllowsTheNextAcquisition() throws {
  let anchor = temporaryAnchor()
  defer { try? FileManager.default.removeItem(at: anchor) }

  do {
    let held = StoreRelocationLock(at: anchor, exclusive: true)
    #expect(held != nil)
  }   // deinit here

  #expect(StoreRelocationLock(at: anchor, exclusive: true) != nil)
}

/// The anchor is deliberately NOT inside the support directory. flock binds to an inode, so a
/// cross-volume copy would hand the writer a different inode of an identically-named file and the
/// guard would evaporate in exactly the case it exists for.
@Test func anchorIsOutsideTheSupportDirectory() {
  let anchor = StoreRelocationLock.anchorURL().path
  #expect(!anchor.hasPrefix(PensievePaths.defaultSupportDirectory().path))
  #expect(anchor.hasSuffix("/Library/Caches/me.mazetti.pensieve/relocation.lock"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test FILTER=StoreRelocationLock`
Expected: FAIL — compile error, `StoreRelocationLock` does not exist.

- [ ] **Step 3: Write the implementation**

Create `Sources/PensieveKit/Store/StoreRelocationLock.swift`:

```swift
import Foundation
import os

/// An advisory whole-file lock coordinating a store relocation against concurrent canonical
/// writers, across processes.
///
/// The anchor is deliberately OUTSIDE the support directory. `flock` binds to an inode: if the
/// lockfile lived in the directory being relocated, a same-volume rename would preserve it and
/// everything would appear to work, while a cross-volume copy would hand the writer a *different*
/// inode of an identically-named file — the guard would evaporate in precisely the case it exists
/// for.
///
/// Non-blocking by design. A writer that cannot acquire does not wait; it reports "not now" and
/// exits so its next scheduled run picks the work up.
public final class StoreRelocationLock: @unchecked Sendable {
  private let descriptor: Int32

  /// `~/Library/Caches/me.mazetti.pensieve/relocation.lock` — a path that never relocates.
  public static func anchorURL() -> URL {
    PensievePaths.homeDirectory()
      .appendingPathComponent("Library/Caches/me.mazetti.pensieve", isDirectory: true)
      .appendingPathComponent("relocation.lock")
  }

  /// Acquires the lock, or returns nil if it is held incompatibly. Creating the anchor is
  /// best-effort: if the Caches directory cannot be made, this returns nil, which callers treat
  /// as "someone else is relocating" — the conservative direction (a writer declines to run
  /// rather than running unguarded).
  public init?(at url: URL = StoreRelocationLock.anchorURL(), exclusive: Bool) {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let opened = open(url.path, O_RDWR | O_CREAT, 0o644)
    guard opened >= 0 else { return nil }
    let mode = (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB
    guard flock(opened, mode) == 0 else {
      close(opened)
      return nil
    }
    descriptor = opened
  }

  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test FILTER=StoreRelocationLock`
Expected: PASS — four tests.

- [ ] **Step 5: Mutation-check the exclusion**

Temporarily change `LOCK_EX` to `LOCK_SH` in the implementation. Run `make test FILTER=StoreRelocationLock`.
Expected: `exclusiveLockExcludesSharedAndExclusive` FAILS. **Revert the mutation.** If it passed, the test is vacuous and must be fixed before proceeding — this project has shipped two vacuous tests and caught both only by running the mutation.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Store/StoreRelocationLock.swift \
        Tests/PensieveKitTests/StoreRelocationLockTests.swift
git commit -m "feat(kit): an advisory relocation lock anchored outside the store"
```

---

### Task 3: Wire the lock into `openCanonical()`

One process-wide shared lock, acquired lazily on first canonical-writer open. The spool stays untouched — that property gets its own mutation-verified test, because it is the one most likely to be quietly broken later.

**Files:**
- Modify: `Sources/PensieveKit/Store/StoreOpen.swift`
- Test: `Tests/PensieveKitTests/StoreOpenTests.swift`

**Interfaces:**
- Consumes: `StoreRelocationLock` (Task 2), `resolvedCanonicalURL()` / `resolvedSpoolURL()` (Task 1).
- Produces:
  - `enum StoreError: Error { case relocationInProgress }`
  - `openCanonical()` throws `StoreError.relocationInProgress` while a relocation holds the anchor.

- [ ] **Step 1: Write the failing test**

Append to `Tests/PensieveKitTests/StoreOpenTests.swift`:

```swift
/// While a relocation holds the anchor exclusively, a canonical WRITER must refuse to open.
/// Without this the writer would write into a directory being copied out from under it.
@Test func openCanonicalRefusesDuringRelocation() throws {
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("canon-\(UUID().uuidString).sqlite")
  setenv("PENSIEVE_DB", temporary.path, 1)
  defer { unsetenv("PENSIEVE_DB"); try? FileManager.default.removeItem(at: temporary) }

  let anchor = FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
  defer { try? FileManager.default.removeItem(at: anchor) }
  let relocator = StoreRelocationLock(at: anchor, exclusive: true)
  #expect(relocator != nil)

  #expect(throws: StoreError.relocationInProgress) {
    _ = try openCanonicalWriter(anchor: anchor)
  }
}

/// The SPOOL is the capture path and must NEVER be gated. A git hook fires on every commit and
/// must not block or fail because a relocation happens to be running; rows it writes during the
/// window are recovered by the relocator's post-commit re-drain instead.
@Test func openSpoolIsNeverGatedByRelocation() throws {
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("cap-\(UUID().uuidString).sqlite")
  setenv("PENSIEVE_CAPTURE_DB", temporary.path, 1)
  defer { unsetenv("PENSIEVE_CAPTURE_DB"); try? FileManager.default.removeItem(at: temporary) }

  let anchor = FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
  defer { try? FileManager.default.removeItem(at: anchor) }
  let relocator = StoreRelocationLock(at: anchor, exclusive: true)
  #expect(relocator != nil)

  let spool = try openSpool()
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}")
  #expect(FileManager.default.fileExists(atPath: temporary.path))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test FILTER=Relocation`
Expected: FAIL — `StoreError` and `openCanonicalWriter(anchor:)` do not exist.

- [ ] **Step 3: Write the implementation**

Add to `Sources/PensieveKit/Store/StoreOpen.swift`:

```swift
public enum StoreError: Error, Equatable {
  /// A store relocation holds the anchor. Not a failure — callers should report "not now" and
  /// exit 0 so their next scheduled run picks the work up.
  case relocationInProgress
}

/// The process's shared relocation lock, acquired ONCE on the first canonical-writer open and held
/// until the process exits.
///
/// Process lifetime is the correct granularity because every canonical writer here is short-lived:
/// `pensieve sync` and the launchd helper each run one cycle and terminate. The app is the one
/// long-lived writer and never conflicts with itself, because it performs relocation *before*
/// opening any store. A killed process releases the lock automatically when the kernel closes its
/// descriptors.
private let processWriterLock = OSAllocatedUnfairLock<StoreRelocationLock?>(initialState: nil)

/// Testable core: `anchor` is injectable so a test never touches the real
/// `~/Library/Caches/me.mazetti.pensieve/relocation.lock`, which the developer's running app holds.
func openCanonicalWriter(anchor: URL) throws -> any DatabaseWriter {
  guard StoreRelocationLock(at: anchor, exclusive: false) != nil else {
    throw StoreError.relocationInProgress
  }
  return try openCanonicalDatabase(at: resolvedCanonicalURL())
}
```

Then rewrite `openCanonical()` to take the process lock once and delegate:

```swift
/// Opens the canonical store for WRITING at the resolved location (override for tests via
/// PENSIEVE_DB). Refuses while a relocation is in progress.
public func openCanonical() throws -> any DatabaseWriter {
  try processWriterLock.withLock { held in
    if held == nil {
      guard let acquired = StoreRelocationLock(exclusive: false) else {
        throw StoreError.relocationInProgress
      }
      held = acquired
    }
    return try openCanonicalDatabase(at: resolvedCanonicalURL())
  }
}
```

Import `os` at the top of the file for `OSAllocatedUnfairLock`.

> **Do not add a lock to `openSpool()`, `openCanonicalReadOnly()`, `openCanonicalDatabase(at:)` or `CaptureSpool(at:)`.** The first is the sacred capture path; the second is a reader and readers never block a relocation; the last two are the explicit-URL variants the relocator itself uses, and locking them would make it deadlock against its own exclusive lock.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test FILTER=Relocation`
Expected: PASS — both new tests.

- [ ] **Step 5: Mutation-check that the spool really is ungated**

Temporarily add the same `guard StoreRelocationLock(...)` to `openSpool()`. Run `make test FILTER=openSpoolIsNeverGated`.
Expected: FAIL. **Revert the mutation.** If it passed, the test proves nothing about the property that matters most here.

- [ ] **Step 6: Run the whole suite**

Run: `make test`
Expected: PASS. The two pre-existing `StoreOpenTests` still pass — nothing acquires the real anchor during a normal test run.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Store/StoreOpen.swift Tests/PensieveKitTests/StoreOpenTests.swift
git commit -m "feat(kit): canonical writers defer to a relocation, the spool never does"
```

---

### Task 4: The relocator state machine

The copy-verify-commit-recycle operation, entirely in Kit, entirely testable over injected directories.

**Files:**
- Create: `Sources/PensieveKit/Store/StoreRelocator.swift`
- Test: `Tests/PensieveKitTests/StoreRelocatorTests.swift`

**Interfaces:**
- Consumes: `StoreRelocationLock` (Task 2), `PensievePaths.canonicalURL(in:)` / `captureURL(in:)` (Task 1), `openCanonicalDatabase(at:)`, `CaptureSpool(at:)`, `Ingester`.
- Produces:
  - `struct StoreRelocator`
  - `init(source: URL, destination: URL, anchor: URL, defaults: UserDefaults, recycle: @Sendable (URL) -> Bool)`
  - `func run(progress: @Sendable (Double) -> Void) async throws -> Report`
  - `struct Report { let movedBytes: Int64; let recoveredRows: Int; let oldFolderRecycled: Bool }`
  - `enum RelocationError: Error { case lockUnavailable, destinationNotWritable, destinationInsideSource, destinationIsSource, destinationNotEmpty, insufficientSpace(needed: Int64, available: Int64), verificationFailed(String) }`
  - `static func preflight(source: URL, destination: URL) -> RelocationError?`

- [ ] **Step 1: Write the failing preflight test**

Create `Tests/PensieveKitTests/StoreRelocatorTests.swift`:

```swift
import Testing
import Foundation
import SQLiteData
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test FILTER=preflightRefuses`
Expected: FAIL — `StoreRelocator` does not exist.

- [ ] **Step 3: Write preflight**

Create `Sources/PensieveKit/Store/StoreRelocator.swift` with the error type and preflight:

```swift
import Foundation
import SQLiteData
import os

public enum RelocationError: Error, Equatable {
  case lockUnavailable
  case destinationNotWritable
  case destinationInsideSource
  case destinationIsSource
  case destinationNotEmpty
  case insufficientSpace(needed: Int64, available: Int64)
  case verificationFailed(String)
}

public struct StoreRelocator {
  public struct Report: Sendable {
    public let movedBytes: Int64
    public let recoveredRows: Int
    public let oldFolderRecycled: Bool
  }

  let source: URL
  let destination: URL
  let anchor: URL
  let defaults: UserDefaults
  let recycle: @Sendable (URL) -> Bool

  public init(source: URL, destination: URL,
              anchor: URL = StoreRelocationLock.anchorURL(),
              defaults: UserDefaults = PensieveDefaults.shared(),
              recycle: @escaping @Sendable (URL) -> Bool) {
    self.source = source; self.destination = destination
    self.anchor = anchor; self.defaults = defaults; self.recycle = recycle
  }

  /// Cheap, pure-ish refusals run before anything is copied, each naming its own reason.
  public static func preflight(source: URL, destination: URL) -> RelocationError? {
    let sourcePath = source.standardizedFileURL.path
    let destinationPath = destination.standardizedFileURL.path

    if destinationPath == sourcePath { return .destinationIsSource }
    // A destination under the source would have the copy write into its own input.
    if destinationPath.hasPrefix(sourcePath + "/") { return .destinationInsideSource }

    let manager = FileManager.default
    if manager.fileExists(atPath: destinationPath) {
      let contents = (try? manager.contentsOfDirectory(atPath: destinationPath)) ?? []
      if !contents.isEmpty { return .destinationNotEmpty }
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
}
```

- [ ] **Step 4: Run the preflight test**

Run: `make test FILTER=preflightRefuses`
Expected: PASS.

- [ ] **Step 5: Write the failing operation tests**

Append to `Tests/PensieveKitTests/StoreRelocatorTests.swift`:

```swift
/// Builds a realistic source: a canonical store with a known event count, a spool, and a
/// disposable index that must travel with the root.
private func makePopulatedSource() throws -> URL {
  let source = try makeTemporaryDirectory()
  let database = try openCanonicalDatabase(at: PensievePaths.canonicalURL(in: source))
  try database.write { db in
    try db.execute(sql: """
      INSERT INTO nodes (id, name, kind, state, context, description, metadataJSON)
      VALUES ('11111111-1111-1111-1111-111111111111', 'Test', 'project', 'active', '', '', '{}')
      """)
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
  // Simulates the hook: append to the OLD spool after the copy, before the flip.
  relocator.afterCopyForTesting = { oldSource in
    let spool = try CaptureSpool(at: PensievePaths.captureURL(in: oldSource))
    try spool.append(kind: CaptureKind.gitCommit, payload: #"{"sha":"deadbeef"}"#)
  }

  let report = try await relocator.run(progress: { _ in })
  #expect(report.recoveredRows == 1)
}
```

- [ ] **Step 6: Run to verify they fail**

Run: `make test FILTER=StoreRelocator`
Expected: FAIL — `run(progress:)` and the two test seams do not exist.

- [ ] **Step 7: Implement `run`**

Add to `StoreRelocator`:

```swift
  /// Test seams. Both default to inert. They exist because the two properties that matter most —
  /// "a failure before the commit point changes nothing" and "a row written during the window is
  /// recovered" — are otherwise only observable by racing a real filesystem.
  var corruptCopyForTesting = false
  var afterCopyForTesting: (@Sendable (URL) throws -> Void)?

  public func run(progress: @Sendable (Double) -> Void) async throws -> Report {
    if let refusal = Self.preflight(source: source, destination: destination) { throw refusal }

    // STEP 1 — exclusive lock. A sync in flight holds a shared lock and wins; the caller reports
    // "sync running, try again" and boots normally against the old root.
    guard let lock = StoreRelocationLock(at: anchor, exclusive: true) else {
      throw RelocationError.lockUnavailable
    }
    defer { _ = lock }   // held until this function returns

    let manager = FileManager.default
    let measuredBytes = Self.directorySize(at: source)
    try Self.checkFreeSpace(needed: measuredBytes, at: destination)

    // Drain the spool into the current canonical store, so as little as possible is in flight.
    let sourceCanonicalURL = PensievePaths.canonicalURL(in: source)
    let sourceSpoolURL = PensievePaths.captureURL(in: source)
    if manager.fileExists(atPath: sourceCanonicalURL.path) {
      let database = try openCanonicalDatabase(at: sourceCanonicalURL)
      let spool = try CaptureSpool(at: sourceSpoolURL)
      _ = try? await Ingester(spool: spool, database: database).drain()
    }

    // STEP 2 — the count that verification will match against.
    let expectedEvents = try Self.eventCount(at: sourceCanonicalURL)
    progress(0.05)

    // STEP 3 — COPY, not move. `moveItem` across volumes is internally copy-then-delete and can
    // leave partial state at the destination on failure; moving to another disk is the whole point
    // of this feature, so the source stays intact until after the commit point.
    do {
      try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                  withIntermediateDirectories: true)
      try manager.copyItem(at: source, to: destination)
    } catch {
      try? manager.removeItem(at: destination)
      throw error
    }
    progress(0.75)

    try? afterCopyForTesting?(source)
    if corruptCopyForTesting {
      try? Data().write(to: PensieveePathsCanonicalCopy(destination))
    }

    // STEP 4 — semantic verification. Byte sizes catch truncation; opening the copy and matching
    // the event count catches the failure that actually matters, without hashing 130 MB.
    do {
      let copiedEvents = try Self.eventCount(at: PensievePaths.canonicalURL(in: destination))
      guard copiedEvents == expectedEvents else {
        throw RelocationError.verificationFailed(
          "event count \(copiedEvents) != \(expectedEvents)")
      }
    } catch {
      try? manager.removeItem(at: destination)
      throw error is RelocationError ? error
        : RelocationError.verificationFailed(String(describing: error))
    }
    progress(0.85)

    // STEP 5 — THE COMMIT POINT.
    defaults.set(destination.path, forKey: PensieveDefaults.customSupportRootKey)

    // STEP 6 — close the window: rows a hook wrote to the OLD spool during 3–5 still arrive.
    var recoveredRows = 0
    if manager.fileExists(atPath: sourceSpoolURL.path) {
      let oldSpool = try? CaptureSpool(at: sourceSpoolURL)
      let newDatabase = try? openCanonicalDatabase(at: PensievePaths.canonicalURL(in: destination))
      if let oldSpool, let newDatabase {
        recoveredRows = (try? await Ingester(spool: oldSpool, database: newDatabase).drain()) ?? 0
      }
    }
    progress(0.95)

    // STEP 7 — the Bin, not unlink. 130 MB of canonical store stays recoverable if the new
    // location turns out to be wrong.
    let didRecycle = recycle(source)
    progress(1.0)

    Log.sync.info("""
      Relocated store: \(measuredBytes, privacy: .public) bytes, \
      recovered \(recoveredRows, privacy: .public) row(s), recycled=\(didRecycle, privacy: .public)
      """)
    return Report(movedBytes: measuredBytes, recoveredRows: recoveredRows,
                  oldFolderRecycled: didRecycle)
  }

  private static func eventCount(at url: URL) throws -> Int {
    let database = try openCanonicalDatabase(at: url)
    return try database.read { db in try Event.fetchCount(db) }
  }

  static func directorySize(at url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(
      at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      total += Int64(size)
    }
    return total
  }

  static func checkFreeSpace(needed: Int64, at destination: URL) throws {
    var probe = destination
    while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
      probe = probe.deletingLastPathComponent()
    }
    let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    let available = values?.volumeAvailableCapacityForImportantUsage ?? 0
    guard available == 0 || available >= needed else {
      throw RelocationError.insufficientSpace(needed: needed, available: available)
    }
  }
```

Replace the placeholder `PensieveePathsCanonicalCopy(destination)` in the corruption seam with `PensievePaths.canonicalURL(in: destination)` — it is written here only to make the seam's intent unmistakable; the real line is:

```swift
    if corruptCopyForTesting {
      try? Data().write(to: PensievePaths.canonicalURL(in: destination))
    }
```

- [ ] **Step 8: Run the relocator tests**

Run: `make test FILTER=StoreRelocator`
Expected: PASS — four tests.

- [ ] **Step 9: Mutation-check the two load-bearing properties**

- Delete the **step 6** block (`recoveredRows` stays 0). Run `make test FILTER=aRowWrittenDuringTheWindow`. Expected: FAIL. Revert.
- Move the **step 5** `defaults.set` to before the step-4 verification. Run `make test FILTER=aFailedVerificationLeavesNothing`. Expected: FAIL. Revert.

If either passed, the test is vacuous. Fix it before proceeding.

- [ ] **Step 10: Lint and commit**

Run: `make lint`
Expected: 0 violations. If `StoreRelocator.swift` exceeds 400 lines, split `preflight`, `directorySize` and `checkFreeSpace` into `StoreRelocator+Preflight.swift`.

```bash
git add Sources/PensieveKit/Store/StoreRelocator.swift \
        Tests/PensieveKitTests/StoreRelocatorTests.swift
git commit -m "feat(kit): a verified copy-commit-recycle store relocator"
```

---

### Task 5: CLI and launchd agent defer instead of failing

Both `SyncRunner` call sites must treat a relocation as "not now" and exit **0**. A non-zero exit would make a routine, expected condition look like the dead-daemon incident of 2026-08-11.

**Files:**
- Modify: `Sources/pensieve/Commands/Sync.swift:9-21`
- Modify: `Sources/PensieveSyncAgent/PensieveSyncAgent.swift:15-26`

**Interfaces:**
- Consumes: `StoreError.relocationInProgress` (Task 3).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Make the CLI defer**

Replace the body of `run()` in `Sources/pensieve/Commands/Sync.swift`:

```swift
  func run() async throws {
    let database: any DatabaseWriter
    do {
      database = try openCanonical()
    } catch StoreError.relocationInProgress {
      // Not a failure: exit 0 so the next scheduled run picks the work up.
      print("\(Date().ISO8601Format()) sync: relocation in progress, skipping")
      return
    }
    let summary = try await SyncRunner(
      spool: try openSpool(),
      database: database,
      provider: makeDefaultLLMProvider(defaults: PensieveDefaults.shared()),
      projectsDir: PensievePaths.claudeProjectsURL(),
      searchIndexer: .production()).run()
    // ISO-timestamped so a silent daemon failure can be correlated to a time.
    print("""
      \(Date().ISO8601Format()) sync: ingested \(summary.ingested) event(s), discovered \(summary.discovered) \
      session(s), extracted \(summary.extracted) loose end(s)
      """)
  }
```

Add `import SQLiteData` to the file if it is not already there (needed for `any DatabaseWriter`).

- [ ] **Step 2: Make the agent defer**

In `Sources/PensieveSyncAgent/PensieveSyncAgent.swift`, replace the `do` block's opening so the relocation case is distinguished from a real failure:

```swift
    do {
      let database: any DatabaseWriter
      do {
        database = try openCanonical()
      } catch StoreError.relocationInProgress {
        SyncLog.append("\(now) sync: relocation in progress, skipping\n",
                       to: PensievePaths.syncLogURL())
        return
      }
      let syncResult = try await SyncRunner(
        spool: try openSpool(),
        database: database,
        provider: makeDefaultLLMProvider(defaults: PensieveDefaults.shared()),
        projectsDir: PensievePaths.claudeProjectsURL(),
        searchIndexer: .production()).run()
      line = "\(now) sync: ingested \(syncResult.ingested) event(s), discovered \(syncResult.discovered) session(s), "
        + "extracted \(syncResult.extracted) loose end(s)\n"
    } catch {
      line = "\(now) sync FAILED: \(error)\n"
    }
```

Add `import SQLiteData` to the file.

- [ ] **Step 3: Build both targets**

Run: `make cli`
Expected: BUILD SUCCEEDED.

Run: `make build`
Expected: BUILD SUCCEEDED (the app scheme builds and embeds both the CLI and the agent helper).

- [ ] **Step 4: Verify the deferral by hand**

The agent has no unit tests, so prove the path with the real binary. In one shell, hold the anchor:

```bash
mkdir -p ~/Library/Caches/me.mazetti.pensieve
/usr/bin/python3 -c "pass" 2>/dev/null; \
  exec 9>~/Library/Caches/me.mazetti.pensieve/relocation.lock && \
  /usr/bin/flock -x 9 && echo "held; press enter to release" && read
```

If `flock(1)` is unavailable on this machine, skip to running the CLI normally and confirm it still syncs — the automated coverage for the refusal itself is Task 3's `openCanonicalRefusesDuringRelocation`.

In a second shell, with a throwaway store so the live one is untouched:

```bash
PENSIEVE_DB=/tmp/reloc-probe.sqlite PENSIEVE_CAPTURE_DB=/tmp/reloc-probe-cap.sqlite \
  ~/.local/bin/pensieve sync; echo "exit=$status"
```

Expected: prints `relocation in progress, skipping` and `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add Sources/pensieve/Commands/Sync.swift Sources/PensieveSyncAgent/PensieveSyncAgent.swift
git commit -m "feat(cli): sync defers to a relocation instead of failing"
```

---

### Task 6: Launch-time relocation and the relauncher

The app performs the move during startup, ahead of `AppModel.start()`, so there are no pools, no observers, and no `FSEventStream` to tear down.

**Files:**
- Create: `Sources/PensieveApp/Settings/RelocationLauncher.swift`
- Create: `Sources/PensieveApp/RelocationProgressView.swift`
- Modify: `Sources/PensieveApp/PensieveApp.swift`
- Modify: `Sources/PensieveApp/AppDefaults.swift`

**Interfaces:**
- Consumes: `StoreRelocator`, `RelocationError` (Task 4), `PensievePaths.supportDirectory()` (Task 1).
- Produces:
  - `AppDefaults.pendingRelocationDestinationKey: String` — `"pendingRelocationDestination"`
  - `enum RelocationLauncher { static func requestRelocation(to: URL); static func pendingDestination() -> URL?; static func clearPending(); static func relaunch() }`
  - `struct RelocationProgressView: View`

- [ ] **Step 1: Add the pending key**

In `Sources/PensieveApp/AppDefaults.swift`:

```swift
  /// Set by Settings when the user confirms a move; read at the NEXT launch, before any store is
  /// opened. Cleared once the relocation finishes, succeeds or fails — a key that survived a
  /// failure would retry the move on every launch forever.
  static let pendingRelocationDestinationKey = "pendingRelocationDestination"
```

- [ ] **Step 2: Write the launcher**

Create `Sources/PensieveApp/Settings/RelocationLauncher.swift`:

```swift
import AppKit
import Foundation
import PensieveKit

/// Requesting a relocation writes an instruction and restarts the app; the NEW instance performs
/// the move during startup, before `AppModel.start()` opens anything.
///
/// This ordering is the whole point. Relocating inside a running session would mean tearing down
/// `AppModel`'s `lazy var searchStore` (which cannot be reset), two app-lifetime `FSEventStream`
/// watches bound to the old directories, and a live `ValueObservation` task — and missing any one
/// strong reference to the pool leaves the app unable to release its own shared lock, failing its
/// own relocation forever. The relaunch was already required, so this reorders it rather than
/// adding one.
enum RelocationLauncher {
  static func requestRelocation(to destination: URL) {
    UserDefaults.standard.set(destination.path, forKey: AppDefaults.pendingRelocationDestinationKey)
    relaunch()
  }

  static func pendingDestination() -> URL? {
    guard let path = UserDefaults.standard.string(
      forKey: AppDefaults.pendingRelocationDestinationKey), !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  static func clearPending() {
    UserDefaults.standard.removeObject(forKey: AppDefaults.pendingRelocationDestinationKey)
  }

  /// Waits for THIS process to exit before reopening the bundle — two instances of the same app
  /// racing over the same store is the one thing worse than the race we are removing.
  static func relaunch() {
    let bundlePath = Bundle.main.bundlePath
    let processIdentifier = ProcessInfo.processInfo.processIdentifier
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c",
      "while /bin/kill -0 \(processIdentifier) 2>/dev/null; do /bin/sleep 0.1; done; "
      + "/usr/bin/open \"\(bundlePath)\""]
    try? task.run()
    NSApp.terminate(nil)
  }
}
```

- [ ] **Step 3: Write the progress view**

Create `Sources/PensieveApp/RelocationProgressView.swift`:

```swift
import SwiftUI

/// Shown instead of the main window while a launch-time relocation runs. Determinate, because the
/// copy's progress is genuinely known and an indeterminate spinner over a 130 MB copy reads as a
/// hang.
struct RelocationProgressView: View {
  let destination: String
  let fraction: Double
  let failure: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let failure {
        Label("Moving Pensieve’s data failed", systemImage: "exclamationmark.triangle")
          .font(.headline)
        Text(failure).font(.callout).foregroundStyle(.secondary)
        Text("Pensieve is still using its previous location. Nothing was lost.")
          .font(.callout).foregroundStyle(.secondary)
      } else {
        Text("Moving Pensieve’s data…").font(.headline)
        ProgressView(value: fraction)
        Text(verbatim: destination)     // a path is content — never localized
          .font(.callout).foregroundStyle(.secondary).lineLimit(2)
      }
    }
    .padding(24)
    .frame(width: 420)
  }
}
```

- [ ] **Step 4: Run the relocation at launch**

In `Sources/PensieveApp/PensieveApp.swift`, add relocation state to the `App` and gate the main window's content on it. Add to the `PensieveApp` struct:

```swift
  @State private var relocationFraction: Double?
  @State private var relocationFailure: String?
  private let pendingRelocation = RelocationLauncher.pendingDestination()
```

Inside the `Window` scene, wrap the existing root content:

```swift
      Group {
        if let pendingRelocation, relocationFailure == nil, relocationFraction ?? 0 < 1 {
          RelocationProgressView(destination: pendingRelocation.path,
                                 fraction: relocationFraction ?? 0,
                                 failure: nil)
        } else if let relocationFailure {
          RelocationProgressView(destination: pendingRelocation?.path ?? "",
                                 fraction: 1, failure: relocationFailure)
        } else {
          RootView(model: model)
        }
      }
      .task {
        guard let pendingRelocation else { return }
        await performRelocation(to: pendingRelocation)
      }
```

And add the method to the struct:

```swift
  /// Runs before `AppModel.start()` — nothing is open yet, which is what makes this safe.
  /// The pending key is cleared on EVERY exit path: a key surviving a failure would retry the
  /// move on every launch forever.
  private func performRelocation(to destination: URL) async {
    let source = PensievePaths.supportDirectory()
    do {
      _ = try await StoreRelocator(
        source: source, destination: destination,
        recycle: { NSWorkspace.shared.recycle([$0], completionHandler: nil); return true }
      ).run(progress: { fraction in
        Task { @MainActor in relocationFraction = fraction }
      })
      RelocationLauncher.clearPending()
      relocationFraction = 1
    } catch {
      RelocationLauncher.clearPending()
      relocationFailure = String(describing: error)
    }
  }
```

> The `RootView` branch is reached only after the relocation finishes, so `AppModel.start()` — which is driven from `RootView`'s `.task` — opens the store at the **new** root. Do not move `AppModel.start()` earlier.

- [ ] **Step 5: Regenerate the project and build**

Run: `make build`
Expected: BUILD SUCCEEDED. (`make build` runs `xcodegen generate` first, which is **required** — two app-target files are new and the `.xcodeproj` is generated and gitignored.)

- [ ] **Step 6: Smoke-launch**

Run:

```bash
PENSIEVE_DB=/tmp/smoke-$(date +%s).sqlite PENSIEVE_CAPTURE_DB=/tmp/smoke-cap-$(date +%s).sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 5; kill %1
```

Expected: no crash. Note honestly that this recipe renders no view body, so it proves the binary launches, **not** that the relocation UI works — that is a human-verify carry.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveApp/Settings/RelocationLauncher.swift \
        Sources/PensieveApp/RelocationProgressView.swift \
        Sources/PensieveApp/PensieveApp.swift \
        Sources/PensieveApp/AppDefaults.swift
git commit -m "feat(app): perform store relocation at launch, before anything opens"
```

---

### Task 7: The Locations row redesign

The presentation half of the original request. No behaviour change beyond removing a redundant button.

**Files:**
- Create: `Sources/PensieveApp/Settings/LocationRow.swift`
- Modify: `Sources/PensieveApp/Settings/AdvancedSettingsTab.swift:29-37,64-80`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct LocationRow: View` with `init(title: LocalizedStringKey, url: URL, status: LocalizedStringKey?, onInspect: (() -> Void)?)`

- [ ] **Step 1: Write the row**

Create `Sources/PensieveApp/Settings/LocationRow.swift`:

```swift
import AppKit
import SwiftUI

/// One filesystem location, in the shape Xcode's Locations pane uses: title and status on the
/// first line, the path on its own line below.
///
/// The path is NOT monospaced and NOT middle-truncated. The previous single-line row rendered
/// `/Users/moritz/Library…nsieve/pensieve.sqlite`, which is neither readable nor selectable — the
/// real path survived only in a tooltip. Monospace made it worse: wider per glyph, and nothing
/// here needs column alignment.
struct LocationRow: View {
  let title: LocalizedStringKey
  let url: URL
  /// `Default` / `Custom`, or nil for a derived location that cannot be configured.
  var status: LocalizedStringKey?
  /// nil for derived locations — an ⓘ opening a modal with no controls would be a lie about
  /// what is configurable.
  var onInspect: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(title)
        Spacer()
        if let status {
          Text(status).foregroundStyle(.secondary)
        }
        if let onInspect {
          Button(action: onInspect) { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .help("Show details")
        }
      }
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(verbatim: url.path)         // a path is content — never localized
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
          Image(systemName: "arrow.right")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.link)
        .help("Reveal in Finder")
      }
    }
  }
}
```

- [ ] **Step 2: Rewrite the section**

In `Sources/PensieveApp/Settings/AdvancedSettingsTab.swift`, replace the `Store & Logs` section (`:29-37`) and delete the private `pathRow` helper (`:64-80`) entirely:

```swift
      Section("Store & Logs") {
        LocationRow(title: "Support Folder",
                    url: PensievePaths.supportDirectory(),
                    status: isCustomRoot ? "Custom" : "Default",
                    onInspect: { isInspectorPresented = true })
        LocationRow(title: "Canonical Store", url: resolvedCanonicalURL())
        LocationRow(title: "Capture Spool", url: resolvedSpoolURL())
        LocationRow(title: "Logs", url: PensievePaths.logsDirectory())
      }
```

Add the supporting state to the view:

```swift
  @State private var isInspectorPresented = false

  /// True when a custom support root is persisted. Read directly rather than mirrored into
  /// `@State`, matching how `SettingsView` reads `Preferences`.
  private var isCustomRoot: Bool {
    PensieveDefaults.shared().string(forKey: PensieveDefaults.customSupportRootKey)?
      .isEmpty == false
  }
```

The standalone `Open Logs Folder` button is removed with the section rewrite — the Logs row's own arrow does that job now.

- [ ] **Step 3: Add the String Catalog keys**

Hand-author in `Sources/PensieveApp/Localizable.xcstrings` (the catalog is IDE-populated only; `xcodebuild` will **not** extract these):

| Key | `en` | `de` |
|---|---|---|
| `Support Folder` | Support Folder | Support-Ordner |
| `Canonical Store` | Canonical Store | Kanonischer Speicher |
| `Capture Spool` | Capture Spool | Erfassungs-Spool |
| `Logs` | Logs | Protokolle |
| `Default` | Default | Standard |
| `Custom` | Custom | Benutzerdefiniert |
| `Show details` | Show details | Details anzeigen |
| `Reveal in Finder` | Reveal in Finder | Im Finder anzeigen |

`Canonical Store`, `Capture Spool`, `Logs` and `Reveal in Finder` already exist in the catalog from the current tab — reuse those entries, do not duplicate them. Remove the now-unused `Open Logs Folder` entry.

German is impersonal/infinitive, per the existing catalog's convention.

- [ ] **Step 4: Build and verify the catalog**

Run: `make build`
Expected: BUILD SUCCEEDED.

Run: `plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -i -E "Support-Ordner|Benutzerdefiniert|Standard"`
Expected: all three present. A missing key falls back to English **silently**, so this check is the only thing that catches a mis-keyed value.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/Settings/LocationRow.swift \
        Sources/PensieveApp/Settings/AdvancedSettingsTab.swift \
        Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): Xcode-shaped location rows, readable and selectable"
```

---

### Task 8: The ⓘ inspector, folder picker and confirmation

**Files:**
- Create: `Sources/PensieveApp/Settings/SupportFolderInspector.swift`
- Modify: `Sources/PensieveApp/Settings/AdvancedSettingsTab.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `StoreRelocator.preflight`, `RelocationError`, `StoreRelocator.directorySize` (Task 4); `RelocationLauncher.requestRelocation(to:)` (Task 6); `PensieveDefaults.customSupportRootKey` (Task 1).
- Produces: `struct SupportFolderInspector: View`

- [ ] **Step 1: Write the inspector**

Create `Sources/PensieveApp/Settings/SupportFolderInspector.swift`:

```swift
import AppKit
import SwiftUI
import PensieveKit

/// The ⓘ sheet for the support folder: current location, size on disk, and the Default/Custom
/// switch that triggers a verified move.
///
/// Choosing `Custom` picks a CONTAINER and Pensieve uses `<chosen>/Pensieve`, shown in full in the
/// confirmation before anything happens. A deliberate deviation from Xcode: picking `/Volumes/Work`
/// and being refused for "not empty" would be maddening, and the appended component mirrors the
/// default layout exactly.
struct SupportFolderInspector: View {
  @Environment(\.dismiss) private var dismiss

  @State private var pendingDestination: URL?
  @State private var refusal: String?
  @State private var measuredBytes: Int64 = 0

  private var currentRoot: URL { PensievePaths.supportDirectory() }
  private var isCustom: Bool {
    PensieveDefaults.shared().string(forKey: PensieveDefaults.customSupportRootKey)?
      .isEmpty == false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Form {
        LabeledContent("Location") {
          Picker("Location", selection: locationBinding) {
            Text("Default").tag(false)
            Text("Custom").tag(true)
          }
          .labelsHidden()
          .fixedSize()
        }
        Text(verbatim: currentRoot.path)        // content — never localized
          .font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        Text(byteText).font(.callout).foregroundStyle(.secondary)
        if let refusal {
          Label(refusal, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 420)
    .task { measuredBytes = StoreRelocator.directorySize(at: currentRoot) }
    .confirmationDialog(confirmationTitle, isPresented: confirmationBinding) {
      Button("Move and Relaunch") {
        if let pendingDestination { RelocationLauncher.requestRelocation(to: pendingDestination) }
      }
      Button("Cancel", role: .cancel) { pendingDestination = nil }
    } message: {
      Text("\(byteText) will be copied. The old folder is moved to the Bin after verification, and Pensieve relaunches.")
    }
  }

  private var byteText: String {
    ByteCountFormatStyle(style: .file).format(measuredBytes)
  }

  private var confirmationTitle: String {
    guard let pendingDestination else { return "" }
    return String(localized: "Move Pensieve’s data to \(pendingDestination.path)?")
  }

  private var confirmationBinding: Binding<Bool> {
    Binding(get: { pendingDestination != nil },
            set: { if !$0 { pendingDestination = nil } })
  }

  private var locationBinding: Binding<Bool> {
    Binding(get: { isCustom }, set: { wantsCustom in
      refusal = nil
      wantsCustom ? chooseCustomFolder() : proposeMove(to: PensievePaths.defaultSupportDirectory())
    })
  }

  private func chooseCustomFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = String(localized: "Choose")
    guard panel.runModal() == .OK, let container = panel.url else { return }
    proposeMove(to: container.appendingPathComponent("Pensieve", isDirectory: true))
  }

  /// Pre-flight first, so a bad destination is refused by name instead of failing mid-copy.
  private func proposeMove(to destination: URL) {
    if let error = StoreRelocator.preflight(source: currentRoot, destination: destination) {
      refusal = Self.message(for: error, measuredBytes: measuredBytes)
      return
    }
    pendingDestination = destination
  }

  /// Each refusal names its own reason. A generic failure would leave the user guessing which of
  /// five different mistakes they made.
  static func message(for error: RelocationError, measuredBytes: Int64) -> String {
    switch error {
    case .destinationIsSource:
      return String(localized: "Pensieve already uses that folder.")
    case .destinationInsideSource:
      return String(localized: "Choose a folder outside Pensieve’s current one.")
    case .destinationNotEmpty:
      return String(localized: "That folder already contains a Pensieve folder with files in it.")
    case .destinationNotWritable:
      return String(localized: "Pensieve can’t write to that folder.")
    case .insufficientSpace:
      return String(localized: "There isn’t enough free space on that disk.")
    case .lockUnavailable:
      return String(localized: "A sync is running. Try again in a moment.")
    case .verificationFailed:
      return String(localized: "The copied data didn’t verify. Nothing was changed.")
    }
  }
}
```

- [ ] **Step 2: Present it from the tab**

In `AdvancedSettingsTab.swift`, attach to the `Form`:

```swift
    .sheet(isPresented: $isInspectorPresented) { SupportFolderInspector() }
```

- [ ] **Step 3: Add the String Catalog keys**

| Key | `en` | `de` |
|---|---|---|
| `Location` | Location | Ort |
| `Choose` | Choose | Auswählen |
| `Done` | Done | Fertig |
| `Move and Relaunch` | Move and Relaunch | Bewegen und neu starten |
| `Move Pensieve’s data to %@?` | Move Pensieve’s data to %@? | Pensieves Daten nach %@ bewegen? |
| `%@ will be copied. The old folder is moved to the Bin after verification, and Pensieve relaunches.` | (as written) | %@ werden kopiert. Der alte Ordner wird nach der Überprüfung in den Papierkorb bewegt, und Pensieve startet neu. |
| `Pensieve already uses that folder.` | (as written) | Pensieve verwendet diesen Ordner bereits. |
| `Choose a folder outside Pensieve’s current one.` | (as written) | Einen Ordner außerhalb des aktuellen Pensieve-Ordners auswählen. |
| `That folder already contains a Pensieve folder with files in it.` | (as written) | Dieser Ordner enthält bereits einen Pensieve-Ordner mit Dateien. |
| `Pensieve can’t write to that folder.` | (as written) | Pensieve kann nicht in diesen Ordner schreiben. |
| `There isn’t enough free space on that disk.` | (as written) | Auf diesem Volume ist nicht genügend freier Speicherplatz. |
| `A sync is running. Try again in a moment.` | (as written) | Eine Synchronisierung läuft. Bitte gleich erneut versuchen. |
| `The copied data didn’t verify. Nothing was changed.` | (as written) | Die kopierten Daten konnten nicht überprüft werden. Es wurde nichts geändert. |
| `Moving Pensieve’s data…` | (as written) | Pensieves Daten werden bewegt … |
| `Moving Pensieve’s data failed` | (as written) | Bewegen von Pensieves Daten fehlgeschlagen |
| `Pensieve is still using its previous location. Nothing was lost.` | (as written) | Pensieve verwendet weiterhin den vorherigen Ort. Es sind keine Daten verloren gegangen. |
| `Cancel` | Cancel | Abbrechen |

`Cancel` and `Done` already exist in the catalog — reuse, do not duplicate. Note the `%@` placeholders: these are `String(localized:)` interpolations, so the catalog key must carry `%@` exactly where the interpolation sits, or the German value silently falls back.

- [ ] **Step 4: Build and verify**

Run: `make build`
Expected: BUILD SUCCEEDED.

Run: `plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -c "."`
Expected: a count that grew by the number of new keys. Then spot-check three of the longest German values by eye for `%@` placement.

- [ ] **Step 5: Lint**

Run: `make lint`
Expected: 0 violations. If `AdvancedSettingsTab.swift` or `SupportFolderInspector.swift` exceeds 400 lines, split the refusal-message mapping into `SupportFolderInspector+Messages.swift`.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/Settings/SupportFolderInspector.swift \
        Sources/PensieveApp/Settings/AdvancedSettingsTab.swift \
        Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): choose a custom support folder, with a verified move"
```

---

### Task 9: Full verification and documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `CONTINUE.md`
- Modify: `docs/superpowers/backlog.md`

- [ ] **Step 1: Run everything CI runs**

Run: `make all`
Expected: lint 0 violations · tests PASS (baseline 753 + roughly 12 new = ~765 in 18 suites) · app builds · embedded-CLI smoke passes.

- [ ] **Step 2: Confirm the default path is byte-identical**

With no custom root set, prove nothing moved for an existing install:

```bash
~/.local/bin/pensieve status
```

Expected: reports the same store at `~/Library/Application Support/Pensieve/pensieve.sqlite` as before this branch, with the same counts. **Do not run `make install` yet** — it replaces the live `/Applications/Pensieve.app` and re-mints the sync helper's cdhash. That is the human's call.

- [ ] **Step 3: Document in CLAUDE.md**

Add a bullet to the Status list, after the transcript-passage-chunking entry, covering: the one-root custom support folder; the collapse of four path resolvers into one; the `flock` anchored outside the moving directory and why (inode binding); that git hooks take no lock and rows written during the window are recovered post-commit; that the relocation runs at launch before anything opens; the Locations-pane redesign; and the spec/plan paths.

- [ ] **Step 4: Record the human-verify carries in CONTINUE.md**

These need the built app installed at `/Applications` and the real store — none of them are reachable from `make all`, and the app target has no unit tests:

- The pane reads better: path legible and selectable, arrow reveals the right file, no window jump when switching Settings tabs.
- A **same-volume** move (e.g. to `~/Documents`) completes, relaunches, and shows the same project and loose-end counts as before.
- A **cross-volume** move (external disk) does the same. This is the case the lock exists for.
- The old folder is in the Bin, not gone.
- `pensieve list` agrees with the app after the move — the cross-process proof that a separate process reads the defaults key.
- `tail -f ~/Library/Logs/Pensieve/sync.log` shows the agent resuming against the new location within ~300 s. **This closes the one open risk in the spec:** `PensieveDefaults.shared()` is proven cross-process from a CLI context but not from a launchd-spawned helper specifically.
- A `git commit` **during** the move still shows up afterwards (the step-6 property, in situ).
- Reverting to Default moves the data back.
- German in situ for the ~24 new keys.

- [ ] **Step 5: Note the deferred items in backlog.md**

- Per-file custom paths and a custom Logs location — deliberately out of scope, not foreclosed.
- The stale `.bak` files and retired `preferences.json` in the support directory are pre-existing debris that now get copied on every relocation. Mentioned, not deleted, per surgical-change discipline.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md CONTINUE.md docs/superpowers/backlog.md
git commit -m "docs: record the custom store location and its verify carries"
```

---

## Self-Review

**Spec coverage.** §1 path resolution → Task 1. §2 the lock → Tasks 2, 3, 5. §3 the operation → Tasks 4, 6. §4 the UI → Tasks 7, 8. §5 localization → folded into Tasks 7 and 8, verified in both. Testing section → Tasks 2–4 carry the six named Kit tests plus the three required mutation checks; "app half is build + eyeball" → Task 9 step 4. Human-verify carries → Task 9 step 4. Open risks → the launchd defaults read is explicitly the `sync.log` carry in Task 9.

**Type consistency.** `resolvedCanonicalURL()` / `resolvedSpoolURL()` are defined in Task 1 and consumed in Tasks 5, 7. `StoreRelocationLock(at:exclusive:)` is defined in Task 2 and consumed in Tasks 3, 4. `RelocationError` cases are defined in Task 4 and exhaustively switched in Task 8 — the two lists match, all seven cases. `StoreRelocator.directorySize(at:)` is `static` in Task 4 and called statically in Task 8. `PensieveDefaults.customSupportRootKey` (Kit, cross-process) and `AppDefaults.pendingRelocationDestinationKey` (app-only) are deliberately different keys in different domains and are never interchanged.

**Signatures verified against the tree, not assumed.** `Ingester.drain() async throws -> Int` (`Ingester.swift:49`) — so `recoveredRows` in Task 4 is an `Int` as written. `CaptureKind.gitCommit == "git.commit"` (`CapturePayloads.swift:4`) — the constant used in Tasks 3 and 4 exists and is spelled correctly. `openCanonicalDatabase(at:) -> any DatabaseWriter` and `openCanonicalDatabaseReadOnly(at:) -> any DatabaseReader` (`CanonicalStore.swift:4,16`) are the non-locking explicit-URL variants the relocator relies on. `CaptureSpool.init(at:) throws` and `append(kind:payload:at:)` (`CaptureSpool.swift:15,34`) match Task 4's usage.

**One thing an executor must not "fix".** Task 4's `defer { _ = lock }` looks like dead code and lints as suspicious. It is the mechanism that holds the exclusive lock for the whole function body — deleting it releases the lock at the point of last use, which for an optimizing compiler can be immediately after acquisition. If SwiftLint objects, silence it with an explicit comment at that line rather than removing it.
