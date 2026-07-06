# Pensieve.app slice 3b — Liveness · Inspector · Recall Windows — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Pensieve.app a ⌘⌥I provenance inspector (surrounding transcript context), side-by-side recall windows (⌘⌥N), a semantic-color polish pass, and true event-driven liveness (retire the 3 s Timer) — all read-only over tested PensieveKit kernels, trust gate untouched.

**Architecture:** One new tested PensieveKit read-only kernel (`ProvenanceContext`) resolves a loose end's surrounding transcript with an `isUserPrompt`+quote two-part guard so a stale index never highlights the wrong message. The app grows a `.inspector` panel, a secondary `WindowGroup(for: UUID.self)` recall scene (the single `Window("main")` + deep-link/intent bridge stay untouched), a small `NodeStateStyle` helper, and a liveness rewrite: GRDB `ValueObservation` + two directory `FSEventStream`s (spool incl. `-wal` → self-drain; canonical incl. `-wal` → refresh) coalesced through a tested `Debouncer`.

**Tech Stack:** Swift 6, SwiftUI (`.inspector`, `WindowGroup`, `openWindow`), SQLiteData/GRDB (`DatabasePool`, `ValueObservation`), CoreServices `FSEventStream`, Swift Testing. App target built via XcodeGen + Xcode; PensieveKit via SwiftPM.

## Global Constraints

- **Design/spec of record:** `docs/superpowers/specs/2026-07-06-three-pane-slice3b-liveness-inspector-windowing-design.md`. Every task implicitly includes its "Data & write path" and "trust gate" rules.
- **Do NOT modify `Sources/PensieveKit/Capture/CapturePayloads.swift`** — a parallel session has uncommitted work there. (Calling its public `encodeJSON` from tests is fine; editing the file is not.)
- **PensieveKit predicates use `.eq(x)`, not `== x`.** Tables are `STRICT`; PKs are `UUID`. Reuse `CaptureKind`/`SourceKind` constants. No shared mutable `static ISO8601DateFormatter`.
- **Swift only. No Python.** YAGNI, TDD, surgical changes, frequent commits.
- **PensieveKit tests** run with `swift test` (or `./scripts/test.sh`), Swift Testing (`import Testing`, `@Test`, `#expect`). Temp DBs via the existing `tempURL(_:ext:)` helper (`Tests/PensieveKitTests/TestSupport.swift`).
- **The app target has no unit tests** — app-layer tasks verify by an `xcodebuild` build + a **non-blocking** smoke-launch of the inner binary with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`. Build:
  ```bash
  xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
  ```
  Inner binary: `./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`.
- **Deployment target is macOS 15** (already set). `.inspector`, `WindowGroup(for:)`, `openWindow` are all available.
- **Task order is fixed: 1 → 2 → 3 → 4.** Liveness is LAST (riskiest / most isolatable). Each task ends green and is independently useful.
- **Work in an isolated git worktree** branched from `main` (see Execution Handoff). Commit after every task.

---

## File Structure

- **Create** `Sources/PensieveKit/Query/ProvenanceQueries.swift` — the `ProvenanceContext`/`ProvenanceMessage` types + `ProvenanceQueries.context(...)` kernel (Task 1).
- **Create** `Tests/PensieveKitTests/ProvenanceQueriesTests.swift` — kernel tests (Task 1).
- **Create** `Sources/PensieveApp/InspectorView.swift` — the ⌘⌥I panel (Task 2).
- **Modify** `Sources/PensieveApp/AppModel.swift` — `showInspector`, `inspectedLooseEndID` (+ clear-on-`selectedNodeID`), `provenance(for:)` (Task 2); liveness wiring (Task 4).
- **Modify** `Sources/PensieveApp/DetailView.swift` — `allowsInspector` init param gating the inspector-selection write (Task 2).
- **Modify** `Sources/PensieveApp/RootView.swift` — attach `.inspector`; the ⌘⌥N open-window `.onChange` (Tasks 2–3).
- **Modify** `Sources/PensieveApp/PensieveApp.swift` — Go ▸ Inspector (⌘⌥I) command; the recall `WindowGroup`; File ▸ Open in New Window (⌘⌥N) command (Tasks 2–3).
- **Create** `Sources/PensieveApp/RecallWindowView.swift` — the focused recall scene root (Task 3).
- **Modify** `Sources/PensieveApp/AppModel.swift` — add a semantic `color` to the existing `SmartListKind` (Task 3; reuses its `.symbol`, avoids a parallel enum).
- **Modify** `Sources/PensieveApp/SidebarView.swift` — tint the smart-list row icons with `kind.color` (Task 3).
- **Create** `Sources/PensieveKit/Support/Debouncer.swift` — trailing-edge coalescer (Task 4).
- **Create** `Tests/PensieveKitTests/DebouncerTests.swift` — debouncer tests (Task 4).
- **Create** `Sources/PensieveKit/Support/DirectoryWatcher.swift` — `FSEventStream` directory watcher (Task 4).
- **Modify** `Sources/PensieveKit/Store/CanonicalStore.swift` — add busy `.timeout` to the writable pool (Task 4).

---

## Task 1: `ProvenanceContext` kernel (PensieveKit, TDD)

Pure read-only kernel. No app changes. Resolves a loose end → its source event → the surrounding transcript window, with the two-part guard.

**Files:**
- Create: `Sources/PensieveKit/Query/ProvenanceQueries.swift`
- Test: `Tests/PensieveKitTests/ProvenanceQueriesTests.swift`

**Interfaces:**
- Consumes: `LooseEnd` (`sourceEventID`, `sourceMessageIndex`, `quote`), `Event` (`detailJSON` with `transcriptPath`), `TranscriptParser.parse(fileURL:) -> ParsedSession` (`messages: [TranscriptMessage]` with `index`, `role`, `text`, `isUserPrompt`).
- Produces:
  ```swift
  public struct ProvenanceMessage: Sendable, Equatable {
    public let index: Int
    public let role: String
    public let text: String
    public let isCited: Bool     // the message the loose end was extracted from
    public let isUserPrompt: Bool
  }
  public struct ProvenanceContext: Sendable {
    public let looseEnd: LooseEnd
    public let sourceEvent: Event
    public let messages: [ProvenanceMessage]   // radius window; empty when unavailable
    public let transcriptAvailable: Bool       // false → UI shows stored quote + honest note
  }
  public enum ProvenanceQueries {
    public static func context(_ db: any DatabaseReader, looseEnd: LooseEnd, radius: Int = 4) throws -> ProvenanceContext
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/ProvenanceQueriesTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// Writes a minimal JSONL transcript and returns its URL. Lines are (type, text);
/// type "user" prose → isUserPrompt true; "assistant" or a tool_result → false.
private func writeTranscript(_ prefix: String, _ lines: [(type: String, text: String)]) throws -> URL {
  let url = tempURL(prefix, ext: "jsonl")
  let jsonl = lines.map { line in
    #"{"type":"\#(line.type)","cwd":"/p/app","timestamp":"2026-06-29T13:03:43.382Z","message":{"role":"\#(line.type)","content":"\#(line.text)"}}"#
  }.joined(separator: "\n")
  try jsonl.write(to: url, atomically: true, encoding: .utf8)
  return url
}

/// Inserts an event whose detailJSON points at `transcriptURL`, plus a loose end citing
/// message index `citedIndex` with `quote`. Returns the inserted loose end.
private func seedLooseEnd(_ db: any DatabaseWriter, transcriptURL: URL,
                          citedIndex: Int, quote: String) throws -> LooseEnd {
  let (node, source) = try ProjectResolver(db: db).resolve(path: "/p/app", kind: SourceKind.claudeCode)
  let detail = try encodeJSON(["transcriptPath": transcriptURL.path, "sessionID": "s", "prompts": "2"])
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "session", detailJSON: detail, fingerprint: "fp")
  let le = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "finish the migration",
                    quote: quote, role: "user", sourceMessageIndex: citedIndex)
  try db.write { db in
    try Event.insert { event }.execute(db)
    try LooseEnd.insert { le }.execute(db)
  }
  return le
}

@Test func provenanceReturnsWindowAroundCitedUserPrompt() throws {
  let db = try openCanonicalDatabase(at: tempURL("prov-happy"))
  let url = try writeTranscript("prov-happy", [
    (type: "user", text: "hello there"),                                  // index 0
    (type: "assistant", text: "sure working on it"),                      // index 1
    (type: "user", text: "we still need to finish the migration"),        // index 2 (cited)
    (type: "assistant", text: "got it"),                                  // index 3
    (type: "user", text: "thanks"),                                       // index 4
  ])
  let le = try seedLooseEnd(db, transcriptURL: url, citedIndex: 2, quote: "finish the migration")

  let ctx = try ProvenanceQueries.context(db, looseEnd: le, radius: 1)
  #expect(ctx.transcriptAvailable)
  #expect(ctx.messages.map(\.index) == [1, 2, 3])          // radius 1 around index 2
  let cited = ctx.messages.first { $0.isCited }
  #expect(cited?.index == 2)
  #expect(cited?.text.contains("finish the migration") == true)
  #expect(cited?.isUserPrompt == true)
}

@Test func provenanceClampsWindowAtEdges() throws {
  let db = try openCanonicalDatabase(at: tempURL("prov-edge"))
  let url = try writeTranscript("prov-edge", [
    (type: "user", text: "start the work now"),                          // index 0 (cited)
    (type: "assistant", text: "ok"),                                     // index 1
  ])
  let le = try seedLooseEnd(db, transcriptURL: url, citedIndex: 0, quote: "start the work")
  let ctx = try ProvenanceQueries.context(db, looseEnd: le, radius: 4)
  #expect(ctx.transcriptAvailable)
  #expect(ctx.messages.map(\.index) == [0, 1])              // no negative indices
  #expect(ctx.messages.first?.isCited == true)
}

@Test func provenanceMissingTranscriptDegradesHonestly() throws {
  let db = try openCanonicalDatabase(at: tempURL("prov-missing"))
  let gone = tempURL("prov-missing-gone", ext: "jsonl")     // never written to disk
  let le = try seedLooseEnd(db, transcriptURL: gone, citedIndex: 0, quote: "anything")
  let ctx = try ProvenanceQueries.context(db, looseEnd: le, radius: 4)
  #expect(ctx.transcriptAvailable == false)
  #expect(ctx.messages.isEmpty)
}

@Test func provenanceRejectsOutOfBoundsIndex() throws {
  let db = try openCanonicalDatabase(at: tempURL("prov-oob"))
  let url = try writeTranscript("prov-oob", [(type: "user", text: "only message here")])
  let le = try seedLooseEnd(db, transcriptURL: url, citedIndex: 99, quote: "only message")
  let ctx = try ProvenanceQueries.context(db, looseEnd: le, radius: 4)
  #expect(ctx.transcriptAvailable == false)                 // no message with index 99
  #expect(ctx.messages.isEmpty)
}

@Test func provenanceRejectsSamePhraseNonUserFalseMatch() throws {
  // Index drift resolves sourceMessageIndex to a NON-user message that happens to contain the
  // quote. Requiring isUserPrompt on the cited message must reject it → honest fallback, never
  // a wrong highlight.
  let db = try openCanonicalDatabase(at: tempURL("prov-false"))
  let url = try writeTranscript("prov-false", [
    (type: "user", text: "please handle the retry logic"),               // index 0
    (type: "assistant", text: "handle the retry logic like this"),       // index 1 (non-user, same phrase)
  ])
  let le = try seedLooseEnd(db, transcriptURL: url, citedIndex: 1, quote: "handle the retry logic")
  let ctx = try ProvenanceQueries.context(db, looseEnd: le, radius: 2)
  #expect(ctx.transcriptAvailable == false)                 // cited message isUserPrompt == false → rejected
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter provenance`
Expected: FAIL — `ProvenanceQueries` / `ProvenanceContext` are undefined (compile error).

- [ ] **Step 3: Write the kernel**

Create `Sources/PensieveKit/Query/ProvenanceQueries.swift`:

```swift
import Foundation
import SQLiteData

public struct ProvenanceMessage: Sendable, Equatable {
  public let index: Int
  public let role: String
  public let text: String
  public let isCited: Bool
  public let isUserPrompt: Bool
}

public struct ProvenanceContext: Sendable {
  public let looseEnd: LooseEnd
  public let sourceEvent: Event
  public let messages: [ProvenanceMessage]
  public let transcriptAvailable: Bool
}

/// Read-only resolution of a loose end's surrounding transcript context — the ⌘⌥I inspector's
/// data. Shows real captured text or degrades to `transcriptAvailable == false` (UI then shows the
/// stored verbatim quote + an honest "gone" note). Never fabricates; never highlights a wrong
/// message (two-part guard: the cited message must be a user prompt AND still contain the quote).
public enum ProvenanceQueries {
  public static func context(_ db: any DatabaseReader, looseEnd: LooseEnd, radius: Int = 4) throws -> ProvenanceContext {
    let event = try db.read { db in
      try Event.where { $0.id.eq(looseEnd.sourceEventID) }.fetchOne(db)
    }
    guard let event else { throw ProvenanceError.missingSourceEvent }

    func unavailable() -> ProvenanceContext {
      ProvenanceContext(looseEnd: looseEnd, sourceEvent: event, messages: [], transcriptAvailable: false)
    }

    // transcriptPath lives in the cc.session detailJSON (see Ingester); decode as [String: String].
    guard let path = (try? JSONDecoder().decode([String: String].self, from: Data(event.detailJSON.utf8)))?["transcriptPath"],
          FileManager.default.fileExists(atPath: path)
    else { return unavailable() }

    let session = TranscriptParser.parse(fileURL: URL(fileURLWithPath: path))
    // Resolve by identity (index), not bare position — robust to parser-version drift.
    guard let citedPos = session.messages.firstIndex(where: { $0.index == looseEnd.sourceMessageIndex })
    else { return unavailable() }

    // Two-part guard so "never a wrong highlight" holds: the cited message must be a user prompt
    // AND still contain the stored quote. Either fails → honest fallback.
    let citedMessage = session.messages[citedPos]
    guard citedMessage.isUserPrompt, citedMessage.text.contains(looseEnd.quote) else { return unavailable() }

    let lo = max(0, citedPos - radius)
    let hi = min(session.messages.count - 1, citedPos + radius)
    let window = session.messages[lo...hi].map {
      ProvenanceMessage(index: $0.index, role: $0.role, text: $0.text,
                        isCited: $0.index == looseEnd.sourceMessageIndex, isUserPrompt: $0.isUserPrompt)
    }
    return ProvenanceContext(looseEnd: looseEnd, sourceEvent: event, messages: window, transcriptAvailable: true)
  }
}

public enum ProvenanceError: Error { case missingSourceEvent }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter provenance`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full suite (no regressions)**

Run: `swift test`
Expected: PASS — previous count + 5.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/ProvenanceQueries.swift Tests/PensieveKitTests/ProvenanceQueriesTests.swift
git commit -m "feat: ProvenanceContext kernel — surrounding transcript context for loose ends"
```

---

## Task 2: ⌘⌥I provenance inspector (app-layer)

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift`
- Modify: `Sources/PensieveApp/DetailView.swift`
- Modify: `Sources/PensieveApp/RootView.swift`
- Modify: `Sources/PensieveApp/PensieveApp.swift`
- Create: `Sources/PensieveApp/InspectorView.swift`

**Interfaces:**
- Consumes: `ProvenanceQueries.context(_:looseEnd:radius:)`, `ProvenanceContext`, `AppModel.detail(for:)`.
- Produces: `AppModel.showInspector: Bool`, `AppModel.inspectedLooseEndID: UUID?`, `AppModel.provenance(for looseEnd: LooseEnd) async -> ProvenanceContext?`, `DetailView(model:node:allowsInspector:)`.

- [ ] **Step 1: Add inspector state + accessor to `AppModel`**

In `Sources/PensieveApp/AppModel.swift`, add these `@Published` properties next to `showPalette`:

```swift
  /// Drives the ⌘⌥I provenance inspector (main window only). Toggled by the Go ▸ Inspector command.
  @Published var showInspector = false
  /// The loose end whose surrounding transcript the inspector shows. Written ONLY by the main
  /// window's DetailView (allowsInspector == true); cleared when the main selection changes.
  @Published var inspectedLooseEndID: UUID? {
    didSet { /* no-op; clearing is driven by selectedNodeID below */ }
  }
```

Change `selectedNodeID` to clear the inspected loose end when the main-window selection changes (the recall window never touches `selectedNodeID`, so it can't clear this):

```swift
  @Published var selectedNodeID: UUID? {
    didSet { if selectedNodeID != oldValue { inspectedLooseEndID = nil } }
  }
```

Add the read-only provenance accessor (mirrors `narration(for:)`), after `detail(for:)`:

```swift
  /// Surrounding-transcript provenance for a loose end, resolved off the main actor (file I/O).
  /// nil only when the source event is missing; a present-but-unavailable transcript returns a
  /// ProvenanceContext with `transcriptAvailable == false`.
  func provenance(for looseEnd: LooseEnd) async -> ProvenanceContext? {
    guard let db else { return nil }
    return try? await Task.detached { try ProvenanceQueries.context(db, looseEnd: looseEnd) }.value
  }
```

- [ ] **Step 2: Gate the inspector-selection write in `DetailView`**

In `Sources/PensieveApp/DetailView.swift`, add the init param near the top of the struct:

```swift
  let node: Node
  /// When false (recall window), tapping a loose end never writes the shared inspector selection.
  var allowsInspector: Bool = true
```

In `looseEndRow(_:)`, extend the chevron `Button` action to also set the inspected loose end when allowed (keep the existing expand/collapse):

```swift
      Button {
        if isOpen { expanded.remove(id) } else { expanded.insert(id) }
        if allowsInspector { model.inspectedLooseEndID = id }
      } label: {
```

- [ ] **Step 3: Create `InspectorView`**

Create `Sources/PensieveApp/InspectorView.swift`:

```swift
// Sources/PensieveApp/InspectorView.swift
import SwiftUI
import PensieveKit

/// The ⌘⌥I deep-dive: the surrounding transcript context for the inspected loose end. Cited message
/// highlighted; non-user (machine-envelope) messages dimmed. Honest "gone" note when the transcript
/// is no longer on disk — never a fabrication.
struct InspectorView: View {
  @ObservedObject var model: AppModel
  /// The loaded loose ends for the current node (for the stored-quote fallback + row lookup).
  let looseEnds: [LooseEndView]
  @State private var context: ProvenanceContext?
  @State private var loading = false

  private var selected: LooseEnd? {
    guard let id = model.inspectedLooseEndID else { return nil }
    return looseEnds.first { $0.looseEnd.id == id }?.looseEnd
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let le = selected {
          Text("PROVENANCE").font(.caption).bold().foregroundStyle(.secondary)
          Text(le.text).font(.headline)
          if let ctx = context, ctx.transcriptAvailable {
            ForEach(ctx.messages, id: \.index) { msg in
              messageRow(msg)
            }
          } else if loading {
            ProgressView().controlSize(.small)
          } else {
            // Honest fallback: the stored verbatim quote + why there's no context.
            Text(le.quote).italic().padding(.leading, 10)
              .overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 3) }
            Text("Source transcript no longer on disk.").font(.caption).foregroundStyle(.secondary)
          }
        } else {
          ContentUnavailableView("Select a loose end", systemImage: "quote.opening",
                                 description: Text("Pick a loose end to see its source."))
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task(id: model.inspectedLooseEndID) {
      context = nil
      guard let le = selected else { return }
      loading = true
      context = await model.provenance(for: le)
      loading = false
    }
  }

  @ViewBuilder private func messageRow(_ msg: ProvenanceMessage) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(msg.role).font(.caption2).foregroundStyle(.tertiary)
      Text(msg.text)
        .font(.callout)
        .padding(.leading, msg.isCited ? 10 : 0)
        .overlay(alignment: .leading) {
          if msg.isCited { Rectangle().fill(.orange).frame(width: 3) }
        }
    }
    .opacity(msg.isUserPrompt ? 1 : 0.55)   // dim machine-envelope context
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
```

- [ ] **Step 4: Attach the inspector in `RootView` + pass `allowsInspector` explicitly**

In `Sources/PensieveApp/RootView.swift`, keep the `DetailView` call explicit and attach `.inspector` to the split view. Replace the detail branch + add the modifier:

```swift
    } detail: {
      if let id = model.selectedNodeID, let node = model.node(id) {
        DetailView(model: model, node: node, allowsInspector: true)
      } else if model.sidebarSelection == .briefing {
        BriefingView(model: model)
      } else {
        ContentUnavailableView("Select a project", systemImage: "sidebar.left")
      }
    }
    .navigationTitle("Pensieve")
    .inspector(isPresented: $model.showInspector) {
      InspectorView(model: model, looseEnds: model.detail(for: model.node(model.selectedNodeID ?? UUID()) ?? Node.placeholder).looseEnds)
        .inspectorColumnWidth(min: 260, ideal: 340, max: 500)
    }
```

> Note: `model.detail(for:)` re-queries; that's acceptable here because the inspector re-evaluates only when `showInspector`/selection changes, not per body eval of the whole tree. If a `Node.placeholder` static doesn't already exist, instead compute `looseEnds` safely: guard the selected node and pass `[]` when nil. Prefer this safer form:

```swift
    .inspector(isPresented: $model.showInspector) {
      let ends = model.selectedNodeID.flatMap(model.node).map { model.detail(for: $0).looseEnds } ?? []
      InspectorView(model: model, looseEnds: ends)
        .inspectorColumnWidth(min: 260, ideal: 340, max: 500)
    }
```

Use the safer form (no `Node.placeholder` needed).

- [ ] **Step 5: Add the ⌘⌥I command in `PensieveApp`**

In `Sources/PensieveApp/PensieveApp.swift`, inside the existing `CommandMenu("Go")`, add below the Refresh button:

```swift
        Button("Inspector") { model.showInspector.toggle() }
          .keyboardShortcut("i", modifiers: [.command, .option])
```

- [ ] **Step 6: Build**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 7: Smoke-launch verify (non-blocking, throwaway store)**

Run:
```bash
BIN=./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve
PENSIEVE_DB=/tmp/s3b-p.sqlite PENSIEVE_CAPTURE_DB=/tmp/s3b-c.sqlite "$BIN" & PID=$!
sleep 4; screencapture -x -o /tmp/s3b-inspector.png; kill $PID
```
Expected: app launches, no crash. (Human follow-up, recorded as a carry: select a loose end, press ⌘⌥I → the inspector shows surrounding transcript with the cited message highlighted; a loose end whose transcript is absent shows the "no longer on disk" note.)

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/DetailView.swift Sources/PensieveApp/RootView.swift Sources/PensieveApp/PensieveApp.swift Sources/PensieveApp/InspectorView.swift
git commit -m "feat: ⌘⌥I provenance inspector (surrounding transcript context)"
```

---

## Task 3: Recall `WindowGroup` (⌘⌥N) + semantic-color polish (app-layer)

**Files:**
- Create: `Sources/PensieveApp/RecallWindowView.swift`
- Modify: `Sources/PensieveApp/PensieveApp.swift`
- Modify: `Sources/PensieveApp/RootView.swift`
- Modify: `Sources/PensieveApp/AppModel.swift`
- Modify: `Sources/PensieveApp/SidebarView.swift`

**Interfaces:**
- Consumes: `DetailView(model:node:allowsInspector:)`, `AppModel.node(_:)`, `AppModel.start()`, `AppModel.selectedNodeID`, the existing `SmartListKind` (`.title`, `.symbol`).
- Produces: `AppModel.openNodeRequest: UUID?`, `RecallWindowView(model:nodeID:)`, `SmartListKind.color`.

- [ ] **Step 1: Add the open-in-new-window request signal to `AppModel`**

In `Sources/PensieveApp/AppModel.swift`, add:

```swift
  /// Set by File ▸ Open in New Window (⌘⌥N); observed by RootView, which opens a recall window
  /// via its own openWindow environment and clears it. (RootView is a View, so it reliably has
  /// openWindow; a Commands struct's environment access is less reliable — hence this bridge.)
  @Published var openNodeRequest: UUID?
```

- [ ] **Step 2: Add a semantic `color` to the existing `SmartListKind`**

In `Sources/PensieveApp/AppModel.swift`, `SmartListKind` already has `.title` and `.symbol`. Add a `color` computed property using system semantic roles (auto-adapting in light/dark; only the three surfaced buckets — `blocked`/`orphaned` are gated/unbuilt per the parent design, deliberately not styled):

```swift
  var color: Color {
    switch self {
    case .whatsNext: return .accentColor
    case .dormant: return .secondary
    case .recentlyActive: return .green
    }
  }
```

(`AppModel.swift` already `import SwiftUI`, so `Color` is in scope.)

- [ ] **Step 3: Tint the sidebar smart-list icons with `kind.color`**

In `Sources/PensieveApp/SidebarView.swift`, `smartRow(_:count:)` renders the icon as `Image(systemName: kind.symbol)`. Add the tint (surgical — nothing else changes):

```swift
    } icon: {
      Image(systemName: kind.symbol)
        .foregroundStyle(kind.color)
    }
```

- [ ] **Step 4: Create `RecallWindowView`**

Create `Sources/PensieveApp/RecallWindowView.swift`:

```swift
// Sources/PensieveApp/RecallWindowView.swift
import SwiftUI
import PensieveKit

/// A focused, single-node recall window (⌘⌥N). Reuses DetailView WITHOUT an inspector
/// (allowsInspector: false) so a loose-end tap here never touches the main window's inspector.
/// Reads the shared AppModel; a cold-restored window may briefly resolve nil before the store
/// loads — it re-renders when @Published forest/allNodes refresh, so the first nil is transient.
struct RecallWindowView: View {
  @ObservedObject var model: AppModel
  let nodeID: UUID

  var body: some View {
    Group {
      if let node = model.node(nodeID) {
        DetailView(model: model, node: node, allowsInspector: false)
      } else {
        ContentUnavailableView("Project unavailable", systemImage: "questionmark.folder")
      }
    }
    .frame(minWidth: 480, minHeight: 360)
    .navigationTitle(model.node(nodeID)?.name ?? "Pensieve")
    .task { model.start() }   // idempotent; ensures the store is open on cold restore
  }
}
```

- [ ] **Step 5: Add the recall `WindowGroup` scene + ⌘⌥N command in `PensieveApp`**

In `Sources/PensieveApp/PensieveApp.swift`, add a second scene after the main `Window(...)` block (before or after `MenuBarExtra` — order doesn't matter):

```swift
    WindowGroup("Recall", id: "recall", for: UUID.self) { $nodeID in
      if let nodeID {
        RecallWindowView(model: model, nodeID: nodeID)
      }
    }
```

Add a File-menu command for ⌘⌥N inside `.commands` (a new `CommandGroup`):

```swift
      CommandGroup(after: .newItem) {
        Button("Open in New Window") { model.openNodeRequest = model.selectedNodeID }
          .keyboardShortcut("n", modifiers: [.command, .option])
          .disabled(model.selectedNodeID == nil)
      }
```

- [ ] **Step 6: Fulfil the open request in `RootView` via its `openWindow` environment**

In `Sources/PensieveApp/RootView.swift`, add the environment + an `.onChange` that opens the recall window and clears the request:

```swift
struct RootView: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow
```

and attach after `.sheet(...)`:

```swift
    .onChange(of: model.openNodeRequest) { _, id in
      guard let id else { return }
      openWindow(id: "recall", value: id)
      model.openNodeRequest = nil
    }
```

- [ ] **Step 7: Build**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 8: Smoke-launch verify (non-blocking, throwaway store)**

Run:
```bash
BIN=./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve
PENSIEVE_DB=/tmp/s3b-p.sqlite PENSIEVE_CAPTURE_DB=/tmp/s3b-c.sqlite "$BIN" & PID=$!
sleep 4; screencapture -x -o /tmp/s3b-recall.png; kill $PID
```
Expected: launches, no crash. (Human carry: select a node, ⌘⌥N opens a recall window on it; a loose-end tap there does NOT change the main window's inspector; open a second recall window — each keeps its own node; sidebar state colors legible in light & dark.)

- [ ] **Step 9: Commit**

```bash
git add Sources/PensieveApp/RecallWindowView.swift Sources/PensieveApp/PensieveApp.swift Sources/PensieveApp/RootView.swift Sources/PensieveApp/AppModel.swift Sources/PensieveApp/SidebarView.swift
git commit -m "feat: recall WindowGroup (⌘⌥N) + semantic-color sidebar polish"
```

---

## Task 4: Liveness — retire the 3 s Timer (PensieveKit + app)

**Files:**
- Create: `Sources/PensieveKit/Support/Debouncer.swift`
- Test: `Tests/PensieveKitTests/DebouncerTests.swift`
- Create: `Sources/PensieveKit/Support/DirectoryWatcher.swift`
- Modify: `Sources/PensieveKit/Store/CanonicalStore.swift`
- Modify: `Sources/PensieveApp/AppModel.swift`

**Interfaces:**
- Consumes: `openCanonicalDatabase(at:)`, `Ingester.drain()`, `SpotlightIndexer.reindex()`, `MonitorSnapshot.gather(...)`.
- Produces: `Debouncer(interval:action:)` with `schedule()`; `DirectoryWatcher(paths:onChange:)`.

- [ ] **Step 1: Write the failing `Debouncer` test**

Create `Tests/PensieveKitTests/DebouncerTests.swift`:

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func debouncerCoalescesRapidCallsIntoOneTrailingFire() async throws {
  actor Counter { var n = 0; func bump() { n += 1 }; func value() -> Int { n } }
  let counter = Counter()
  let d = Debouncer(interval: 0.1) { await counter.bump() }
  for _ in 0..<5 { await d.schedule() }          // 5 rapid calls within the window
  try await Task.sleep(nanoseconds: 300_000_000) // 0.3 s > interval
  #expect(await counter.value() == 1)             // coalesced to a single trailing fire
}

@Test func debouncerFiresAgainAfterQuietPeriod() async throws {
  actor Counter { var n = 0; func bump() { n += 1 }; func value() -> Int { n } }
  let counter = Counter()
  let d = Debouncer(interval: 0.1) { await counter.bump() }
  await d.schedule()
  try await Task.sleep(nanoseconds: 250_000_000)
  await d.schedule()
  try await Task.sleep(nanoseconds: 250_000_000)
  #expect(await counter.value() == 2)             // two separated bursts → two fires
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter debouncer`
Expected: FAIL — `Debouncer` undefined.

- [ ] **Step 3: Implement `Debouncer`**

Create `Sources/PensieveKit/Support/Debouncer.swift`:

```swift
import Foundation

/// Trailing-edge coalescer: rapid `schedule()` calls collapse into a single `action` run, fired
/// `interval` seconds after the last call. Used to coalesce the liveness signals (ValueObservation
/// + two FSEvents watches) into one refresh. Actor-isolated; the action runs on a detached Task.
public actor Debouncer {
  private let interval: TimeInterval
  private let action: @Sendable () async -> Void
  private var task: Task<Void, Never>?

  public init(interval: TimeInterval, action: @escaping @Sendable () async -> Void) {
    self.interval = interval
    self.action = action
  }

  public func schedule() {
    task?.cancel()
    task = Task { [interval, action] in
      try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await action()
    }
  }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter debouncer`
Expected: PASS (2 tests).

- [ ] **Step 5: Add a busy timeout to the writable canonical pool**

In `Sources/PensieveKit/Store/CanonicalStore.swift`, change `openCanonicalDatabase` so the writable pool waits on contention (the app is now a frequent concurrent writer alongside the daemon):

```swift
public func openCanonicalDatabase(at url: URL) throws -> any DatabaseWriter {
  try PensievePaths.ensureParentDirectory(of: url)
  var configuration = Configuration()
  configuration.busyMode = .timeout(5)   // wait, don't throw SQLITE_BUSY, under writer contention
  let db = try DatabasePool(path: url.path, configuration: configuration)  // WAL, multi-process
  try migrateCanonical(db)
  return db
}
```

- [ ] **Step 6: Run the full suite (store change is safe)**

Run: `swift test`
Expected: PASS — all prior tests + the 2 debouncer tests. (`CanonicalStoreTests` still open/migrate fine.)

- [ ] **Step 7: Commit the PensieveKit pieces**

```bash
git add Sources/PensieveKit/Support/Debouncer.swift Tests/PensieveKitTests/DebouncerTests.swift Sources/PensieveKit/Store/CanonicalStore.swift
git commit -m "feat: Debouncer coalescer + canonical busy timeout (liveness groundwork)"
```

- [ ] **Step 8: Implement `DirectoryWatcher` (FSEvents, app-linkable infrastructure)**

Create `Sources/PensieveKit/Support/DirectoryWatcher.swift`:

```swift
import Foundation
import CoreServices

/// Watches one or more directories for any filesystem change and invokes `onChange`. Path-based
/// (FSEvents), so it survives SQLite recreating `-wal`/`-shm` on checkpoint — more robust than a
/// per-file vnode source. Coalescing/latency is left to the caller's Debouncer. App-lifetime:
/// hold a strong reference for as long as you want events; deinit tears the stream down.
public final class DirectoryWatcher {
  private var stream: FSEventStreamRef?
  private let onChange: () -> Void

  /// - Parameter paths: directories to watch (e.g. the canonical store's and spool's parent dirs).
  public init(paths: [String], latency: TimeInterval = 0.05, onChange: @escaping () -> Void) {
    self.onChange = onChange
    var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                   retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
      watcher.onChange()
    }
    guard let stream = FSEventStreamCreate(
      kCFAllocatorDefault, callback, &ctx, paths as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
    ) else { return }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.pensieve.fswatch"))
    FSEventStreamStart(stream)
  }

  deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}
```

- [ ] **Step 9: Rewire `AppModel` liveness — drop the Timer, add the observation + watches**

In `Sources/PensieveApp/AppModel.swift`:

(a) Replace the stored `timer` with liveness holders:

```swift
  private var db: (any DatabaseWriter)?
  private var allNodes: [Node] = []
  private var observationTask: Task<Void, Never>?
  private var spoolWatcher: DirectoryWatcher?
  private var canonicalWatcher: DirectoryWatcher?
  private lazy var refreshDebouncer = Debouncer(interval: 0.15) { [weak self] in
    await MainActor.run { self?.refresh(); Task { await self?.reindexSpotlight() } }
  }
  private lazy var drainDebouncer = Debouncer(interval: 0.15) { [weak self] in
    await self?.drainThenRefreshFromWatch()
  }
  private var started = false
```

(b) Rewrite `start()` to install the observation + two directory watches instead of the timer:

```swift
  func start() {
    guard !started else { return }
    started = true
    db = try? openCanonicalDatabase(at: Stores.canonicalURL)
    Task { await drainThenRefresh() }

    // Liveness (retires the 3 s Timer). Watches are app-lifetime (this @StateObject never deinits),
    // so the menu-bar glyph stays live even when the main window is closed.
    if let db {
      observationTask = Task { [weak self] in
        let observation = ValueObservation.tracking { db in try Event.fetchCount(db) }
        do {
          for try await _ in observation.values(in: db) {
            await self?.refreshDebouncer.schedule()   // in-process writes (own drains, future edits)
          }
        } catch { /* observation ended; watches still cover changes */ }
      }
    }
    let canonicalDir = Stores.canonicalURL.deletingLastPathComponent().path
    let spoolDir = Stores.spoolURL.deletingLastPathComponent().path
    canonicalWatcher = DirectoryWatcher(paths: [canonicalDir]) { [weak self] in
      Task { await self?.refreshDebouncer.schedule() }   // catches the EXTERNAL daemon's writes
    }
    spoolWatcher = DirectoryWatcher(paths: [spoolDir]) { [weak self] in
      Task { await self?.drainDebouncer.schedule() }      // new git/session activity → self-drain
    }
  }
```

> Note: `Event.fetchCount(db)` is the tracked region — any insert/delete of events re-fires. `ValueObservation`/`fetchCount` come from SQLiteData's re-exported GRDB. If `Event.fetchCount` isn't directly available, use `try #sql("SELECT count(*) FROM events").fetchOne(db) ?? 0` inside the `tracking` closure.

(c) Add the watch-driven drain (drain only, no cache-clear/refreshToken bump — those belong to launch/⌘R), and a Spotlight helper:

```swift
  /// Watch-triggered drain: ingest new spool rows on our own connection. The resulting canonical
  /// change trips ValueObservation + the canonical watch → refreshDebouncer. Does NOT clear the
  /// narration cache or bump refreshToken (those are launch/⌘R semantics).
  private func drainThenRefreshFromWatch() async {
    if let db, let spool = try? CaptureSpool(at: Stores.spoolURL) {
      _ = try? await Ingester(spool: spool, db: db).drain()
    }
  }

  private func reindexSpotlight() async { await SpotlightIndexer.reindex() }
```

(d) Delete the old timer line in `start()` (the `Timer.scheduledTimer(...)` block) and the `private var timer: Timer?` declaration — both replaced above. Leave `refreshGlance()`, `drainThenRefresh()`, `refresh()`, `refreshNow()` intact (the menu-bar popover still calls `refreshGlance()` on open; ⌘R still calls `drainThenRefresh()`).

- [ ] **Step 10: Build**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 11: Smoke-launch — verify live update without ⌘R**

Run:
```bash
BIN=./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve
rm -f /tmp/s3b-live-*.sqlite*
PENSIEVE_DB=/tmp/s3b-live-p.sqlite PENSIEVE_CAPTURE_DB=/tmp/s3b-live-c.sqlite "$BIN" & PID=$!
sleep 3
# Append a capture out-of-band using the CLI against the SAME throwaway spool, then observe:
PENSIEVE_DB=/tmp/s3b-live-p.sqlite PENSIEVE_CAPTURE_DB=/tmp/s3b-live-c.sqlite swift run pensieve capture-session-start --cwd "$PWD" 2>/dev/null || true
sleep 2; screencapture -x -o /tmp/s3b-live.png; kill $PID
```
Expected: app launches and stays up; no crash on the FSEvents/observation path. (Human carry: with a real store, a new commit/session appears without pressing ⌘R; idle app shows no 3 s churn; the menu-bar glyph updates on real activity.)

- [ ] **Step 12: Full suite once more**

Run: `swift test`
Expected: PASS (all prior + debouncer). Confirms the PensieveKit additions didn't regress anything.

- [ ] **Step 13: Commit**

```bash
git add Sources/PensieveKit/Support/DirectoryWatcher.swift Sources/PensieveApp/AppModel.swift
git commit -m "feat: event-driven liveness — ValueObservation + FSEvents watches, retire 3s Timer"
```

---

## Self-Review (completed against the spec)

**Spec coverage:** Part 1 Liveness → Task 4 (ValueObservation + spool `-wal`/canonical `-wal` directory watches + debounce + busy timeout + Spotlight-on-refresh + Timer removal). Part 2 Inspector → Tasks 1 (kernel, `isUserPrompt`+quote guard, honest fallback) + 2 (`.inspector`, ⌘⌥I, `allowsInspector` gate, clear-on-`selectedNodeID`, `provenance(for:)`, dim non-user). Part 3 Recall windows → Task 3 (`WindowGroup(for: UUID.self)`, ⌘⌥N via `openNodeRequest`→RootView `openWindow`, `allowsInspector: false`, cold-restore `model.start()` + `ContentUnavailableView`). Part 4 Polish → Task 3 (`SmartListKind.color`, system roles, only surfaced states, sidebar icon tint). Out-of-scope items untouched. ✔

**Placeholder scan:** No TBD/TODO; every code step shows real code; every command has expected output. ✔

**Type consistency:** `ProvenanceContext`/`ProvenanceMessage`/`ProvenanceQueries.context` identical across Tasks 1–2; `allowsInspector` default `true`, passed `true` (main) / `false` (recall); `inspectedLooseEndID`/`showInspector`/`openNodeRequest`/`provenance(for:)` on `AppModel` used consistently; `Debouncer(interval:action:)`+`schedule()` and `DirectoryWatcher(paths:onChange:)` match their call sites. ✔

**Notes for the executor:** app-layer tasks (2–4) have no unit tests by project convention — the build + smoke-launch IS the gate; the human behavioral checks are explicit carries. If `ValueObservation`/`Event.fetchCount` symbol resolution differs under SQLiteData, use the raw `#sql` count fallback noted inline. Keep `CapturePayloads.swift` untouched.
