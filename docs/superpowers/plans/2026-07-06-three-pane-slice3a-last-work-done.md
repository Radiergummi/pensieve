# Three-pane slice 3a: "Last Work Done" narration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an LLM-narrated "Last Work Done" prose recap to the detail view — the app's first LLM call — by wiring the existing tested `SummaryBuilder` into `DetailView`, appearing automatically on open, generated on-device, degrading honestly to nothing when it can't be produced.

**Architecture:** A new tested PensieveKit `SummaryBuilder.narrate(project:events:) → String?` (nil, never a facts-dump, on failure/empty) is the trust-sensitive boundary. `AppModel` (`@MainActor`) owns the on-device provider + a session cache and exposes async `narration(for:events:)` + sync `cachedNarration(for:)`; the provider runs off the main actor. `DetailView` shows the prose above Loose Ends, progressive with a spinner, with a carefully-specified `.task` state machine so no stale/wrong-node prose ever renders.

**Tech Stack:** Swift 6 (language mode), SwiftUI `App`, App reads GRDB/SQLiteData via PensieveKit, `LLMProvider` (on-device FoundationModels via `makeDefaultLLMProvider()`, `claude -p` fallback), Swift Testing, XcodeGen + Xcode.

## Global Constraints

- **`SummaryBuilder` MUST be declared `Sendable`.** An `@MainActor AppModel` holds and `await`s it; without `Sendable` that's a Swift-6 data-race error. Free: it stores only `provider: any LLMProvider`, and `LLMProvider: Sendable`.
- **Narration is best-effort, OUTSIDE the strict grounded-cite trust gate** (like strand naming). The model narrates ONLY the deterministic fact sheet (existing constrained prompt); loose ends stay individually cited. `narrate` returns **`nil`** on no-events / provider-throw / empty-or-whitespace success — **never** substitutes the raw fact sheet.
- **`build`'s existing behavior must not change.** Extracting the shared prompt is a pure refactor; the existing `SummaryBuilderTests` must still pass unchanged.
- **Provider runs off the main actor; never block the UI.** `narrate`/the providers are nonisolated `async`.
- **Keep derivation in tested PensieveKit; views stay thin.** The app target has **no unit tests** — verify app tasks with `xcodebuild` build + a non-blocking smoke-launch of the inner binary (`…/Contents/MacOS/Pensieve`) with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`. Never set those against the live store for real use; smoke tests point them at `/tmp`.
- **Commits:** no backticks inside `git commit -m "…"`. The Bash env appends the repo's Co-Authored-By / Claude-Session trailers.
- **Test cmd:** `./scripts/test.sh [--filter <name>]`. **Build cmd:** `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build` (expect `** BUILD SUCCEEDED **`). Inner binary: `./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`.

---

## File Structure

- `Sources/PensieveKit/Intelligence/SummaryBuilder.swift` — declare `Sendable`; extract `makePrompt`; add `narrate`. (Task 1)
- `Tests/PensieveKitTests/SummaryBuilderNarrateTests.swift` — new; the four `narrate` cases. (Task 1)
- `Sources/PensieveApp/AppModel.swift` — provider + cache + `narration`/`cachedNarration` + `refreshToken` + cache-clear in `drainThenRefresh()`. (Task 2)
- `Sources/PensieveApp/DetailView.swift` — the "Last Work Done" section + the keyed `.task` state machine. (Task 3)

**Dependency order:** Task 1 → Task 2 → Task 3 → Task 4 (verify).

---

## Task 1: `SummaryBuilder.narrate` + `Sendable` + shared prompt (PensieveKit, TDD)

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/SummaryBuilder.swift`
- Test: `Tests/PensieveKitTests/SummaryBuilderNarrateTests.swift` (create)

**Interfaces:**
- Consumes: `LLMProvider` (only `complete(prompt:)` is required; protocol supplies the rest), `LLMError`, `Node`, `Event`, `CaptureKind`.
- Produces:
  - `struct SummaryBuilder: Sendable` (was non-`Sendable`).
  - `public func narrate(project: Node, events: [Event]) async -> String?`.
  - (internal) `private static func makePrompt(facts: String) -> String`, used by both `build` and `narrate`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/SummaryBuilderNarrateTests.swift`:
```swift
import Foundation
import Testing
@testable import PensieveKit

private struct FixedProvider: LLMProvider {
  let text: String
  func complete(prompt: String) async throws -> String { text }
}
private struct ThrowingProvider: LLMProvider {
  func complete(prompt: String) async throws -> String { throw LLMError.providerFailed("nope") }
}

private func sampleEvents(_ n: Int) -> [Event] {
  let node = UUID(), src = UUID()
  return (0..<n).map { i in
    Event(nodeID: node, sourceID: src, occurredAt: Date(), kind: CaptureKind.gitCommit,
          summary: "commit \(i)", detailJSON: "{}", fingerprint: "f\(i)")
  }
}

@Test func narrateReturnsTrimmedProseOnSuccess() async {
  let out = await SummaryBuilder(provider: FixedProvider(text: "  Did the auth work.\n"))
    .narrate(project: Node(name: "colibri"), events: sampleEvents(2))
  #expect(out == "Did the auth work.")   // whitespace trimmed
}

@Test func narrateReturnsNilWhenProviderThrows() async {
  let out = await SummaryBuilder(provider: ThrowingProvider())
    .narrate(project: Node(name: "colibri"), events: sampleEvents(2))
  #expect(out == nil)   // NO raw-facts substitution
}

@Test func narrateReturnsNilOnEmptyOrWhitespaceSuccess() async {
  let out = await SummaryBuilder(provider: FixedProvider(text: "   \n  "))
    .narrate(project: Node(name: "colibri"), events: sampleEvents(2))
  #expect(out == nil)   // empty header would be a fact-dump-as-prose failure
}

@Test func narrateReturnsNilForNoEvents() async {
  let out = await SummaryBuilder(provider: FixedProvider(text: "should not be used"))
    .narrate(project: Node(name: "colibri"), events: [])
  #expect(out == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter narrate`
Expected: FAIL to compile — `value of type 'SummaryBuilder' has no member 'narrate'`.

- [ ] **Step 3: Refactor `SummaryBuilder` (declare `Sendable`, extract `makePrompt`, add `narrate`)**

Edit `Sources/PensieveKit/Intelligence/SummaryBuilder.swift` — change the `struct` line and the body to:
```swift
public struct SummaryBuilder: Sendable {
  private let provider: any LLMProvider
  public init(provider: any LLMProvider) { self.provider = provider }

  /// Deterministic fact sheet the model is allowed to narrate — and nothing beyond it.
  public static func assembleFacts(project: Node, events: [Event]) -> String {
    let lines = events.prefix(15).map { "- \($0.kind): \($0.summary)" }.joined(separator: "\n")
    return "Project: \(project.name)\nRecent activity:\n\(lines)"
  }

  /// The single constrained narration prompt — shared by `build` and `narrate` so the wording
  /// can't drift between them.
  private static func makePrompt(facts: String) -> String {
    """
    Narrate ONLY the facts below into 2-3 sentences of "last work done". Do NOT add any \
    fact, plan, or detail that is not explicitly present. If the facts are thin, say so.

    \(facts)
    """
  }

  public func build(_ db: any DatabaseWriter, node: Node, now: Date) async throws -> ProjectSummary? {
    let status = try ProjectQueries.status(db, node: node, limit: 15)
    guard !status.recentEvents.isEmpty else { return nil }
    let facts = Self.assembleFacts(project: status.project, events: status.recentEvents)
    let narration = (try? await provider.complete(prompt: Self.makePrompt(facts: facts))) ?? facts
    let ends = try LooseEndQueries.open(db, nodeID: status.project.id, now: now)
    return ProjectSummary(
      whatItIs: "\(status.project.name) — \(status.project.state)",
      lastWorkDone: narration,
      looseEnds: ends)
  }

  /// Best-effort prose recap of the given events. Returns nil when there's nothing to narrate
  /// (no events) OR the provider fails/returns empty — never substitutes the raw fact sheet, so a
  /// caller can show a narration section only on a genuine result. Takes events directly (no DB
  /// re-query) so the prose narrates exactly what the caller already displays.
  public func narrate(project: Node, events: [Event]) async -> String? {
    guard !events.isEmpty else { return nil }
    let facts = Self.assembleFacts(project: project, events: events)
    guard let raw = try? await provider.complete(prompt: Self.makePrompt(facts: facts)) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
```
(Leave `public struct ProjectSummary { … }` above it unchanged. The only changes vs. today: `: Sendable`, the extracted `makePrompt`, `build` now calls `makePrompt` instead of the inline string, and the new `narrate`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter narrate`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full suite to confirm `build`'s behavior is unchanged**

Run: `./scripts/test.sh`
Expected: all pass (146 prior + 4 new = 150), including the existing `SummaryBuilderTests` (e.g. `summaryBuildReturnsNarrationAndLooseEnds`) — the prompt-extraction is behavior-preserving.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Intelligence/SummaryBuilder.swift Tests/PensieveKitTests/SummaryBuilderNarrateTests.swift
git commit -m "feat: SummaryBuilder.narrate (nil-honest, Sendable) + shared prompt"
```

---

## Task 2: `AppModel` narration plumbing (app target)

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift`

**Interfaces:**
- Consumes: `SummaryBuilder(provider:).narrate` (Task 1); `makeDefaultLLMProvider()`, `Node`, `Event` (PensieveKit).
- Produces (consumed by Task 3):
  - `@Published private(set) var refreshToken: Int`
  - `func cachedNarration(for node: Node) -> String?` (synchronous)
  - `func narration(for node: Node, events: [Event]) async -> String?`

- [ ] **Step 1: Add the provider, cache, and token (state)**

In `Sources/PensieveApp/AppModel.swift`, add to the private state block (near `private var db`, `private var timer`):
```swift
  private lazy var summaryBuilder = SummaryBuilder(provider: makeDefaultLLMProvider())
  private var narrationCache: [UUID: String] = [:]
  /// Bumped on launch + ⌘R (drainThenRefresh). Views key their reload `.task` on it so the OPEN
  /// detail re-narrates after a refresh. The 3 s Timer calls `refresh()` (not drainThenRefresh), so
  /// this never bumps per tick.
  @Published private(set) var refreshToken = 0
```

- [ ] **Step 2: Add the narration accessors**

Add these methods to `AppModel` (anywhere among its methods):
```swift
  /// Cached narration for `node`, if generated this session. Synchronous — lets the view render a
  /// cached recap instantly, with no spinner.
  func cachedNarration(for node: Node) -> String? { narrationCache[node.id] }

  /// The "Last Work Done" narration for `node`. Returns a session-cached result instantly; otherwise
  /// generates it off the main actor via the Sendable SummaryBuilder, caches a non-nil result, and
  /// returns it. nil when there's nothing to narrate or no provider is reachable (failures are not
  /// cached, so a later ⌘R/open can still produce one).
  func narration(for node: Node, events: [Event]) async -> String? {
    if let cached = narrationCache[node.id] { return cached }
    let text = await summaryBuilder.narrate(project: node, events: events)
    if let text { narrationCache[node.id] = text }
    return text
  }
```

- [ ] **Step 3: Invalidate the cache + bump the token on launch/⌘R**

In `drainThenRefresh()`, insert the two lines between `refresh()` and `await SpotlightIndexer.reindex()` (they are synchronous MainActor mutations before the first `await`, so ordering is deterministic):
```swift
  private func drainThenRefresh() async {
    if let db, let spool = try? CaptureSpool(at: Stores.spoolURL) {
      _ = try? await Ingester(spool: spool, db: db).drain()   // no LLM: spool → events only
    }
    refresh()
    narrationCache.removeAll()   // launch/⌘R: recaps may be stale — regenerate on next open
    refreshToken += 1
    await SpotlightIndexer.reindex()
  }
```

- [ ] **Step 4: Build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `** BUILD SUCCEEDED **`. (Confirms `SummaryBuilder`'s `Sendable` conformance lets the `@MainActor` `narration` method `await` it with no data-race diagnostic. The new methods are unused until Task 3 — that's expected; unused instance methods don't warn.)

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift
git commit -m "feat: AppModel narration provider, session cache, and refreshToken"
```

---

## Task 3: `DetailView` "Last Work Done" section (app target)

**Files:**
- Modify: `Sources/PensieveApp/DetailView.swift`

**Interfaces:**
- Consumes: `model.detail(for:)` (existing), `model.refreshToken`, `model.cachedNarration(for:)`, `model.narration(for:events:)` (Task 2).
- Produces: user-visible "Last Work Done" prose section.

- [ ] **Step 1: Add the state and the load key**

In `Sources/PensieveApp/DetailView.swift`, add to the `@State` block (alongside `recentEvents`/`looseEnds`):
```swift
  @State private var lastWorkDone: String?
  @State private var isNarrating = false
  @State private var loadedNodeID: UUID?   // which node the current prose belongs to
```
And add this file-private type below the struct (or above it):
```swift
private struct DetailLoadKey: Hashable { let nodeID: UUID; let token: Int }
```

- [ ] **Step 2: Add the "Last Work Done" section to the body (prose-first render)**

Insert this **between** the `// WHAT IT IS` `VStack` and the `// LOOSE ENDS` `section(...)` in `body`
(the parent three-pane design orders it right after What It Is, as the highest-value field):
```swift
        // LAST WORK DONE (LLM narration; prose-first — a ready recap always wins over an in-flight
        // flag — and the section is omitted entirely when there's no genuine narration).
        if let lastWorkDone {
          section("Last Work Done") {
            Text(lastWorkDone).font(.body)
          }
        } else if isNarrating {
          section("Last Work Done") {
            ProgressView().controlSize(.small)
          }
        }
```

- [ ] **Step 3: Replace the load `.task` with the keyed state machine**

Replace the existing:
```swift
    .task(id: node.id) {
      let d = model.detail(for: node)
      recentEvents = d.status.recentEvents
      looseEnds = d.looseEnds
    }
```
with:
```swift
    // Re-runs on node change AND on ⌘R (refreshToken). The body order is load-bearing (two
    // independent reviews): reset prose only on a NODE change (so a same-node ⌘R keeps the old
    // recap visible until the new one lands — no flash), reset `isNarrating` on EVERY entry (never
    // leak `true` across a handoff), and guard `Task.isCancelled` before writing (a superseded
    // task's await still resumes — don't let a late result render under the new node).
    .task(id: DetailLoadKey(nodeID: node.id, token: model.refreshToken)) {
      if loadedNodeID != node.id { lastWorkDone = nil }
      loadedNodeID = node.id
      isNarrating = false
      let d = model.detail(for: node)
      recentEvents = d.status.recentEvents
      looseEnds = d.looseEnds
      if let cached = model.cachedNarration(for: node) { lastWorkDone = cached; return }
      isNarrating = true
      let prose = await model.narration(for: node, events: recentEvents)
      guard !Task.isCancelled else { return }   // superseded: new task owns state; don't touch isNarrating
      lastWorkDone = prose
      isNarrating = false
    }
```

- [ ] **Step 4: Build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Non-blocking smoke-launch against a throwaway empty store**

Run:
```bash
PENSIEVE_DB=/tmp/pz-s3a.sqlite PENSIEVE_CAPTURE_DB=/tmp/pz-s3ac.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve & PID=$!
sleep 4; if kill -0 $PID 2>/dev/null; then echo "RUNNING cleanly"; kill $PID 2>/dev/null; else echo "EXITED EARLY"; fi
```
Expected: `RUNNING cleanly` (empty store → no events → no narration attempted → no crash).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/DetailView.swift
git commit -m "feat: Last Work Done narration section in the detail view"
```

---

## Task 4: Full verification + human checklist

**Files:** none (verification only).

- [ ] **Step 1: Full test suite**

Run: `./scripts/test.sh`
Expected: all pass — 146 prior + 4 new `narrate` = **150**. Record the count.

- [ ] **Step 2: Clean build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Record the human-verification checklist for the branch review**

These need a live provider + real data and can't be asserted headlessly — list them in the branch summary for the user to run against the **real** store (a normal `open` of the built app):
  1. Open a project with recent activity → within a couple seconds a 2–3 sentence **"Last Work Done"** recap appears above Loose Ends (spinner first, then prose).
  2. Switch to another project mid-load → the new project **never** briefly shows the previous project's recap; its own spinner/prose appears.
  3. Re-open the first project → its recap appears **instantly** (cached, no spinner).
  4. **⌘R** on an open project → it re-narrates (old recap stays visible until the new one lands; no blank flash).
  5. A project with **no captured activity** → **no** "Last Work Done" section at all (Recent Activity shows "No captured activity").

---

## Self-Review (completed by plan author)

- **Spec coverage:** `narrate` nil-honest + `Sendable` + shared `makePrompt` + trim→nil + 4 tests (T1); provider + session cache + `narration`/`cachedNarration` + `refreshToken` + cache-clear-before-reindex (T2); prose-first section + reset-on-node-change + isNarrating-reset-every-entry + cancel-guard + DetailLoadKey (T3); full verify + the 5 human items incl. node-switch and ⌘R (T4). CLAUDE/CONTINUE/backlog status at merge, per spec.
- **Placeholder scan:** none — every code step has complete code; every run step has an expected result.
- **Type consistency:** `narrate(project:events:) async -> String?`, `narration(for:events:) async -> String?`, `cachedNarration(for:) -> String?`, `refreshToken: Int`, `DetailLoadKey(nodeID:token:)` are used identically across T1→T3. `build` signature untouched.
