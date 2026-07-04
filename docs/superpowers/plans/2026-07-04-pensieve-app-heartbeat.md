# Pensieve.app v0.1 — Heartbeat Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first window of `Pensieve.app` — a native, read-only "heartbeat" that shows Pensieve is alive and collecting work (status dot, last-capture age, spool/event/loose-end counts).

**Architecture:** A pure, testable `MonitorSnapshot.gather(...)` in `PensieveKit` reads both stores read-only and computes the heartbeat; a thin new `PensieveApp` SwiftUI executable target polls it every 3 s and renders one window. The logic lives in the kit so the future `pensieved` daemon reuses it.

**Tech Stack:** Swift 6, SwiftPM, SwiftUI/AppKit (no Xcode — Command Line Tools only), SQLiteData (GRDB-backed), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-04-pensieve-app-heartbeat-design.md`.

## Global Constraints

- **Build/test `PensieveKit` with `./scripts/test.sh` (optionally `--filter <name>`), NOT `swift test`** — this machine is Command Line Tools–only. `swift build` / `swift run` work normally.
- **Command Line Tools only (no Xcode.app).** SwiftUI compiles/links under CLT (verified in a spike). Build the app with `swift build` / `swift run PensieveApp`.
- **SQLiteData predicates use `.eq(x)`, NOT `== x`** (e.g. `.where { $0.status.eq("open") }`). `==` is unavailable.
- **Count with `.fetchAll(db).count`** — the house pattern (`NextQueries.swift:23`); do not assume a `.fetchCount` API exists.
- Kind strings live in `CaptureKind` / `SourceKind` (`CapturePayloads.swift`) — reuse the constants.
- No shared mutable `static ISO8601DateFormatter` (Swift 6 concurrency); use a local instance or `Date`'s ISO strategy/format style.
- **The window is strictly read-only and must never break the sacred capture path.** It never writes data; it never *creates* a store (existence-checks first); reads are WAL-safe.
- **No Python, ever. Swift only.**
- Tests/CLI honor `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` env overrides.
- Disk runs tight; on a SwiftSyntax/macro linker error, `rm -rf .build` and retry.

## Deviation from the spec (decided while planning)

- The spec's original status wording ("canonical store missing → `.notSetUp`") was refined to a
  **spool-driven** rule so the heartbeat reassures during the pre-ingest window (hooks firing but
  `ingest` not yet run): `.notSetUp` only when nothing has been captured *and* nothing ingested;
  `.active` whenever the spool's last capture is recent, even if the canonical store doesn't exist
  yet. The spec file was updated to match (§Architecture status rule).

## File Structure

**Created:**
- `Sources/PensieveKit/Query/MonitorSnapshot.swift` — the `MonitorSnapshot` value + `gather(...)`. One responsibility: read both stores read-only and compute the heartbeat.
- `Sources/PensieveApp/main.swift` — the thin SwiftUI/AppKit app target: an `NSApplication` + one `NSWindow` hosting a SwiftUI view that polls `gather` on a 3 s timer. (Target named `PensieveApp` to avoid a case-insensitive-APFS collision with the `pensieve` CLI target.)
- `Tests/PensieveKitTests/CaptureSpoolTests.swift` — tests for the two new spool helpers.
- `Tests/PensieveKitTests/MonitorSnapshotTests.swift` — tests for `gather`.

**Modified:**
- `Sources/PensieveKit/Store/CaptureSpool.swift` — add `lastCaptureAt()` + `pendingCount()`.
- `Package.swift` — add the `PensieveApp` executable product + target.

---

## Task 1: `CaptureSpool` read-only helpers

Two cheap read-only queries the snapshot needs: the newest capture timestamp (any kind, incl. already-ingested — the heartbeat must survive an ingest) and the un-ingested count.

**Files:**
- Modify: `Sources/PensieveKit/Store/CaptureSpool.swift`
- Create: `Tests/PensieveKitTests/CaptureSpoolTests.swift`

**Interfaces:**
- Consumes: existing `CaptureSpool.init(at:)`, `append(kind:payload:at:)`, `pending()`, `markIngested(_:)`.
- Produces: `func lastCaptureAt() throws -> Date?`, `func pendingCount() throws -> Int`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/CaptureSpoolTests.swift`:

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func lastCaptureAtReflectsNewestRowEvenAfterIngest() throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  #expect(try spool.lastCaptureAt() == nil)                     // empty spool

  let t1 = Date(timeIntervalSince1970: 1_000_000)
  let t2 = Date(timeIntervalSince1970: 2_000_000)
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}", at: t1)
  try spool.append(kind: CaptureKind.ccSession, payload: "{}", at: t2)
  #expect(abs(try spool.lastCaptureAt()!.timeIntervalSince(t2)) < 1)   // newest wins

  let ids = try spool.pending().map(\.id)
  try spool.markIngested(ids)
  #expect(try spool.pendingCount() == 0)
  #expect(abs(try spool.lastCaptureAt()!.timeIntervalSince(t2)) < 1)   // survives ingest
}

@Test func pendingCountCountsOnlyUningested() throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}")
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}")
  #expect(try spool.pendingCount() == 2)
  try spool.markIngested([try spool.pending().first!.id])
  #expect(try spool.pendingCount() == 1)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter CaptureSpool`
Expected: FAIL — `value of type 'CaptureSpool' has no member 'lastCaptureAt'` / `pendingCount`.

- [ ] **Step 3: Implement the two helpers**

In `Sources/PensieveKit/Store/CaptureSpool.swift`, add these methods inside `final class CaptureSpool` (after `markIngested`):

```swift
  /// Newest capture timestamp across ALL rows (including already-ingested), or nil if empty.
  /// This is the real-time "last capture" heartbeat and must survive ingestion.
  public func lastCaptureAt() throws -> Date? {
    try dbQueue.read { db in
      guard let iso = try String.fetchOne(db, sql: "SELECT max(ts) FROM captures") else { return nil }
      return try? Date(iso, strategy: .iso8601)
    }
  }

  /// Count of un-ingested rows (ingested = 0) without materializing them.
  public func pendingCount() throws -> Int {
    try dbQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM captures WHERE ingested = 0") ?? 0
    }
  }
```

(`max(ts)` on an empty table yields a NULL that `String.fetchOne` returns as `nil`. Rows are written with `at.ISO8601Format()` — whole-second — which `Date(_:strategy:.iso8601)` parses, matching the existing `pending()` parse. `String`/`Int.fetchOne(_:sql:)` come from GRDB, already imported in this file.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter CaptureSpool`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Store/CaptureSpool.swift Tests/PensieveKitTests/CaptureSpoolTests.swift
git commit -m "feat: CaptureSpool.lastCaptureAt + pendingCount (read-only heartbeat helpers)"
```

---

## Task 2: `MonitorSnapshot` + `gather`

The pure heartbeat kernel: read both stores read-only, compute status + counts. Never throws to the caller; never creates a store.

**Files:**
- Create: `Sources/PensieveKit/Query/MonitorSnapshot.swift`
- Create: `Tests/PensieveKitTests/MonitorSnapshotTests.swift`

**Interfaces:**
- Consumes: `CaptureSpool.lastCaptureAt()` / `pendingCount()` (Task 1); `openCanonicalDatabase(at:)`; `Event`, `LooseEnd` models; `CaptureKind` / `SourceKind` / `Fingerprint` (tests).
- Produces: `struct MonitorSnapshot` with `enum Status { case active, idle, notSetUp }` and
  `static func gather(canonicalURL:spoolURL:now:activeWithin:) -> MonitorSnapshot`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/MonitorSnapshotTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func gatherMissingStoresIsNotSetUp() {
  let snap = MonitorSnapshot.gather(canonicalURL: tempURL("absent-canon"),
                                    spoolURL: tempURL("absent-spool"), now: Date())
  #expect(snap.status == .notSetUp)
  #expect(snap.lastCaptureAt == nil)
  #expect(snap.eventCount == 0 && snap.spoolPending == 0 && snap.looseEndCount == 0)
}

@Test func gatherRecentSpoolCaptureIsActiveEvenWithoutCanonical() throws {
  let spoolURL = tempURL("spool")
  let spool = try CaptureSpool(at: spoolURL)
  let now = Date(timeIntervalSince1970: 3_000_000)
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}", at: now.addingTimeInterval(-60)) // 1 min ago
  let snap = MonitorSnapshot.gather(canonicalURL: tempURL("absent-canon"), spoolURL: spoolURL,
                                    now: now, activeWithin: 15 * 60)
  #expect(snap.status == .active)          // capture alive before the first ingest
  #expect(snap.spoolPending == 1)
}

@Test func gatherOldSpoolCaptureIsIdle() throws {
  let spoolURL = tempURL("spool")
  let spool = try CaptureSpool(at: spoolURL)
  let now = Date(timeIntervalSince1970: 3_000_000)
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}", at: now.addingTimeInterval(-30 * 60)) // 30 min
  let snap = MonitorSnapshot.gather(canonicalURL: tempURL("absent-canon"), spoolURL: spoolURL,
                                    now: now, activeWithin: 15 * 60)
  #expect(snap.status == .idle)
}

@Test func gatherCountsCanonicalEventsAndOpenLooseEnds() throws {
  let canonURL = tempURL("canon")
  let db = try openCanonicalDatabase(at: canonURL)
  let node = Node(name: "app")
  let src = Source(nodeID: node.id, kind: SourceKind.gitRepo, key: "/p/app/.git")
  let ev = Event(nodeID: node.id, sourceID: src.id, occurredAt: Date(),
                 kind: CaptureKind.gitCommit, summary: "x", detailJSON: "{}",
                 fingerprint: Fingerprint.commit(hash: "abc"))
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { src }.execute(db)
    try Event.insert { ev }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: ev.id, text: "t1", quote: "q1", status: "open")
    }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: node.id, sourceEventID: ev.id, text: "t2", quote: "q2", status: "resolved")
    }.execute(db)
  }
  let snap = MonitorSnapshot.gather(canonicalURL: canonURL, spoolURL: tempURL("absent-spool"), now: Date())
  #expect(snap.eventCount == 1)
  #expect(snap.looseEndCount == 1)         // only the open one is counted
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter MonitorSnapshot`
Expected: FAIL — `cannot find 'MonitorSnapshot' in scope`.

- [ ] **Step 3: Implement `MonitorSnapshot`**

Create `Sources/PensieveKit/Query/MonitorSnapshot.swift`:

```swift
import Foundation
import SQLiteData

/// A read-only snapshot of "is Pensieve alive and collecting?" — the heartbeat kernel shared by
/// the app window and (later) the `pensieved` daemon. Never writes; never creates a store.
public struct MonitorSnapshot: Equatable, Sendable {
  public enum Status: String, Equatable, Sendable { case active, idle, notSetUp }

  public let status: Status
  public let lastCaptureAt: Date?      // newest spool row ts (any kind, incl. ingested); nil if none
  public let spoolPending: Int         // captures with ingested = 0
  public let eventCount: Int           // canonical events
  public let looseEndCount: Int        // canonical loose ends with status == "open"

  public init(status: Status, lastCaptureAt: Date?, spoolPending: Int,
              eventCount: Int, looseEndCount: Int) {
    self.status = status; self.lastCaptureAt = lastCaptureAt
    self.spoolPending = spoolPending; self.eventCount = eventCount; self.looseEndCount = looseEndCount
  }

  /// Reads both stores read-only and computes the heartbeat. Never throws to the caller: an
  /// absent/unreachable store degrades that store's fields to zero/nil. Existence is checked
  /// before opening so this never *creates* a store. Status is spool-driven (capture is the
  /// real-time signal), so it reads `.active` even before the first ingest.
  public static func gather(canonicalURL: URL, spoolURL: URL,
                            now: Date = Date(),
                            activeWithin: TimeInterval = 15 * 60) -> MonitorSnapshot {
    // Spool: the real-time capture heartbeat. Only touch it if it already exists.
    var lastCapture: Date? = nil
    var pending = 0
    if FileManager.default.fileExists(atPath: spoolURL.path),
       let spool = try? CaptureSpool(at: spoolURL) {
      lastCapture = try? spool.lastCaptureAt()
      pending = (try? spool.pendingCount()) ?? 0
    }

    // Canonical store: ingested state. Only open an existing store (opening an already-migrated
    // store performs no data writes).
    var events = 0
    var loose = 0
    if FileManager.default.fileExists(atPath: canonicalURL.path),
       let db = try? openCanonicalDatabase(at: canonicalURL) {
      events = (try? db.read { db in try Event.all.fetchAll(db).count }) ?? 0
      loose = (try? db.read { db in
        try LooseEnd.where { $0.status.eq("open") }.fetchAll(db).count
      }) ?? 0
    }

    let status: Status
    if lastCapture == nil && pending == 0 && events == 0 {
      status = .notSetUp
    } else if let lastCapture, now.timeIntervalSince(lastCapture) <= activeWithin {
      status = .active
    } else {
      status = .idle
    }

    return MonitorSnapshot(status: status, lastCaptureAt: lastCapture,
                           spoolPending: pending, eventCount: events, looseEndCount: loose)
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter MonitorSnapshot`
Expected: PASS (all four tests).

- [ ] **Step 5: Run the full suite to confirm no regression**

Run: `./scripts/test.sh`
Expected: all green (prior tests + Task 1 + Task 2 additions).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/MonitorSnapshot.swift Tests/PensieveKitTests/MonitorSnapshotTests.swift
git commit -m "feat: MonitorSnapshot.gather — read-only heartbeat kernel"
```

---

## Task 3: `Pensieve` app target — the heartbeat window

The thin SwiftUI/AppKit render. No logic beyond formatting; it polls `MonitorSnapshot.gather` every 3 s and draws one window. This task's deliverable is verified by launching it and seeing a window (there is no unit test for the view).

**Files:**
- Modify: `Package.swift` (add the `Pensieve` product + `executableTarget`)
- Create: `Sources/Pensieve/main.swift`

**Interfaces:**
- Consumes: `MonitorSnapshot` (Task 2); `PensievePaths.canonicalURL()` / `captureURL()`; `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` env overrides.
- Produces: the `PensieveApp` executable (`swift run PensieveApp`).

- [ ] **Step 1: Add the executable product + target to `Package.swift`**

In `Package.swift`, add to `products`:

```swift
    .executable(name: "PensieveApp", targets: ["PensieveApp"]),
```

and add to `targets`:

```swift
    .executableTarget(
      name: "PensieveApp",
      dependencies: ["PensieveKit"]
    ),
```

- [ ] **Step 2: Write the app**

Create `Sources/PensieveApp/main.swift`:

```swift
import AppKit
import Foundation
import SwiftUI
import PensieveKit

/// Resolves store locations the same way the CLI does (honors PENSIEVE_DB / PENSIEVE_CAPTURE_DB).
enum Stores {
  static var canonicalURL: URL {
    if let o = ProcessInfo.processInfo.environment["PENSIEVE_DB"] { return URL(fileURLWithPath: o) }
    return (try? PensievePaths.canonicalURL()) ?? URL(fileURLWithPath: "/nonexistent")
  }
  static var spoolURL: URL {
    if let o = ProcessInfo.processInfo.environment["PENSIEVE_CAPTURE_DB"] { return URL(fileURLWithPath: o) }
    return (try? PensievePaths.captureURL()) ?? URL(fileURLWithPath: "/nonexistent")
  }
}

@MainActor
final class HeartbeatModel: ObservableObject {
  @Published var snapshot: MonitorSnapshot =
    .init(status: .notSetUp, lastCaptureAt: nil, spoolPending: 0, eventCount: 0, looseEndCount: 0)
  private var timer: Timer?

  func start() {
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }
  func refresh() {
    snapshot = MonitorSnapshot.gather(canonicalURL: Stores.canonicalURL, spoolURL: Stores.spoolURL)
  }
}

struct HeartbeatView: View {
  @ObservedObject var model: HeartbeatModel

  private var dot: (String, Color) {
    switch model.snapshot.status {
    case .active:   return ("● active", .green)
    case .idle:     return ("○ idle", .secondary)
    case .notSetUp: return ("⚠ not set up", .orange)
    }
  }
  private var lastCaptureLine: String {
    guard let at = model.snapshot.lastCaptureAt else { return "no captures yet" }
    let f = RelativeDateTimeFormatter()
    return "last capture \(f.localizedString(for: at, relativeTo: Date()))"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(dot.0).foregroundStyle(dot.1).font(.headline)
      Text(lastCaptureLine).foregroundStyle(.secondary).font(.subheadline)
      Divider()
      Text("Spool:  \(model.snapshot.spoolPending) pending")
      Text("Events: \(model.snapshot.eventCount)")
      Text("Loose ends: \(model.snapshot.looseEndCount)")
    }
    .font(.system(.body, design: .monospaced))
    .padding(20)
    .frame(width: 280, alignment: .leading)
  }
}

// A plain (unbundled) NSApplication host — no Xcode/app bundle required for the dev workflow.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let model = HeartbeatModel()
model.start()
let window = NSWindow(
  contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
  styleMask: [.titled, .closable, .miniaturizable],
  backing: .buffered, defer: false)
window.title = "Pensieve"
window.center()
window.contentView = NSHostingView(rootView: HeartbeatView(model: model))
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
```

- [ ] **Step 3: Build the app**

Run: `swift build`
Expected: `Build complete!` (if a SwiftSyntax/macro linker error appears, `rm -rf .build` and retry).

- [ ] **Step 4: Verify a window actually appears (the deliverable check)**

This is the one open risk from the spec — that an unbundled `NSApplication` window shows and updates. Launch against a throwaway store with a fresh capture so the dot should read `● active`:

```bash
SP=$(mktemp -d)
export PENSIEVE_CAPTURE_DB="$SP/capture.sqlite" PENSIEVE_DB="$SP/pensieve.sqlite"
.build/debug/pensieve capture-commit --repo "$PWD" --hash test --branch main   # one real spool row
swift run PensieveApp
```

Expected: a titled "Pensieve" window appears showing `● active`, `last capture … seconds ago`, `Spool: 1 pending`, `Events: 0`, `Loose ends: 0`. Close the window (⌘W) to exit.
If no window appears / it can't focus, fall back to wrapping the binary in a minimal hand-written `.app` bundle (`Contents/MacOS/Pensieve` + a tiny `Info.plist` with `CFBundleExecutable`), still no Xcode — record the outcome and adjust before committing.

- [ ] **Step 5: Confirm `PensieveKit` tests still pass**

Run: `./scripts/test.sh`
Expected: all green (adding the app target must not disturb the kit or its tests).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/PensieveApp/main.swift
git commit -m "feat: Pensieve.app v0.1 — heartbeat window (swift run PensieveApp)"
```

---

## Task 4: Update status docs (opportunistic)

**Files:**
- Modify: `CLAUDE.md` (Status section), `docs/superpowers/backlog.md`

- [ ] **Step 1: Update status docs**

In `CLAUDE.md`, add a line under Status noting **Pensieve.app v0.1 (heartbeat window)** shipped: a native read-only window (`swift run Pensieve`) over a shared `MonitorSnapshot` kernel; menu-bar item + `pensieved` still deferred. In `backlog.md`, add a follow-up bullet: **menu-bar item / `LSUIElement` app bundle** (own spec; revisit the Xcode.app decision there) and **wire the window into a real `.app` bundle** if Step 3.4 needed the fallback.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md docs/superpowers/backlog.md
git commit -m "docs: note Pensieve.app v0.1 heartbeat window shipped"
```

---

## Self-Review (completed against the spec)

**Spec coverage:**
- §Architecture 1 `MonitorSnapshot` (pure, testable, read-only, never-throws, degrade-to-notSetUp): Task 2. ✅
- §Architecture status rule (spool-driven active/idle/notSetUp, 15-min threshold): Task 2 `gather` + tests for all three states. ✅ (refined per Deviation note; spec updated to match.)
- §Architecture 2 `Pensieve` target (thin SwiftUI render, 3 s timer, minimal layout): Task 3. ✅
- §Supporting change (`lastCaptureAt` incl. ingested, `pendingCount`): Task 1 + tests. ✅
- §Paths & environment (`PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`, PensievePaths defaults): Task 3 `Stores`. ✅
- §Concurrency (read-only, WAL-safe, never creates a store, no static ISO formatter): Task 2 existence-checks + `try?` degradation. ✅
- §Testing (notSetUp / active / idle / counts open-only / lastCaptureAt survives ingest): Tasks 1–2. ✅
- §Packaging (swift run PensieveApp; verify window appears; `.app` fallback): Task 3 Steps 3–4. ✅
- §Non-goals: no feed/per-project/menu-bar/bundle/daemon/auto-ingest/writes built. ✅

**Placeholder scan:** no TBD/TODO/"handle edge cases"/"similar to Task N" — every code step carries full code and every run step an exact command + expected output. ✅

**Type consistency:** `MonitorSnapshot.init` / `Status` / `gather(canonicalURL:spoolURL:now:activeWithin:)` are identical across Task 2's definition, its tests, and Task 3's consumer; `lastCaptureAt()` / `pendingCount()` signatures match between Task 1 and Task 2; `Event`/`LooseEnd`/`Source`/`Fingerprint.commit` call sites match the real model initializers. ✅
