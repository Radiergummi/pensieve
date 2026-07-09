# Salience Labeling Loop Implementation Plan (Phase 1 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user label each loose end salient (👍) or noise (👎) inline, persist those labels in the canonical store as a training corpus, and drop confirmed-noise from the open set — filling the missing "act on a loose end" UX gap while building the corpus for the future on-device classifier.

**Architecture:** Additive canonical-store columns (`label` confirmed by the user, `labelSuggestion` written by a machine) on `LooseEnd`; a thin tested `LooseEndCommands` writer; the "open loose end" predicate redefined to exclude confirmed noise at every call site; per-item 👍/👎 on the shared `LooseEndRow` (confirmed = filled, suggested = pre-highlighted). No classifier, training, or gate — extraction stays lossless. A one-off throwaway `claude -p` script fills `labelSuggestion` over the backlog at the end.

**Tech Stack:** Swift 6, SQLiteData (GRDB), SwiftUI (app target), Swift Testing, XcodeGen + Xcode for the app bundle.

## Global Constraints

- **Swift only. No Python, ever.**
- **No classifier / training / inference / gate in Phase 1.** Extraction stays lossless (every verified loose end is surfaced). The verbatim trust gate is UNTOUCHED.
- **No "done/resolve" lifecycle; no committed bootstrap CLI; no bulk "accept all suggestions."** (All Phase-2 or deliberate non-goals.)
- **SQLiteData predicates use `.eq(x)` / `.neq(x)`, NOT `==`/`!=`.** Tables are `STRICT`; PKs are `UUID`; migrations are additive.
- **`label` and `labelSuggestion` are `TEXT NOT NULL DEFAULT ''`** (empty = unlabeled). This refines the spec's "nullable/nil": a non-null default keeps `.neq("noise")` correct (a nullable column breaks it under SQL three-valued logic) and matches the existing `v9-node-context` precedent (`context TEXT NOT NULL DEFAULT ''`). Semantics are identical: `""` = the spec's `nil`.
- **Label string values live in `LooseEndLabel`** (`salient` / `noise` / `unlabeled = ""`) — reuse the constants, never hardcode, mirroring `CaptureKind`/`SourceKind`/`NodeContext`.
- **`label` is human-confirmed only** (written by the app via `LooseEndCommands.setLabel`). **`labelSuggestion` is machine-written** (`LooseEndCommands.suggest`). **The training corpus reads `label` only** — `labelSuggestion` never enters it.
- **Open loose end = `status == "open"` AND `label != "noise"`**, applied consistently at EVERY open-loose-end read: `LooseEndQueries` (×2), `MonitorSnapshot` (×2), `NodeFacts` (×1), `NextQueries` (×1). `BriefingQueries` routes through `LooseEndQueries.open`, so it inherits the filter. A merely-*suggested*-noise item (`labelSuggestion == "noise"`, `label == ""`) stays visible — a suggestion is not a decision.
- **The app (`Sources/PensieveApp/`) has no unit tests.** Verify app tasks with `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`, then a non-blocking smoke-launch of the inner binary (`./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`, background + `kill`; throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`). Keep logic in tested PensieveKit; keep the view thin.
- **App writes match the existing `try?` + explicit `refresh()` pattern** (as slice-4 organizing writes do). Full error-presentation is the separate, still-open "organizing-writes error surfacing" gap — do NOT build it here.
- **Kit tests:** `./scripts/test.sh` (thin `swift test` passthrough), or `./scripts/test.sh --filter <name>`.
- **App chrome strings are localized** (English base + German `de`) in `Sources/PensieveApp/Localizable.xcstrings`, hand-reconciled (xcodebuild does not auto-populate keys). Loose-end content is never localized.
- **Commit-message trailer** on every commit (backticks in a `-m` message get shell-executed — use `git commit -F` with a quoted heredoc):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```

## File Structure

**PensieveKit**
- Modify `Sources/PensieveKit/Model/LooseEnd.swift` — add `label`, `labelSuggestion`.
- Modify `Sources/PensieveKit/Store/CanonicalStore.swift` — migration `v11-looseend-label`.
- Create `Sources/PensieveKit/Query/LooseEndCommands.swift` — `LooseEndLabel` + `setLabel`/`suggest`/`corpus`.
- Modify `Sources/PensieveKit/Query/LooseEndQueries.swift` — exclude confirmed noise (×2).
- Modify `Sources/PensieveKit/Query/MonitorSnapshot.swift` — exclude confirmed noise (×2).
- Modify `Sources/PensieveKit/Query/NodeFacts.swift` — exclude confirmed noise (×1).
- Modify `Sources/PensieveKit/Query/NextQueries.swift` — exclude confirmed noise (×1).

**Tests**
- Create `Tests/PensieveKitTests/SchemaV11Tests.swift`.
- Create `Tests/PensieveKitTests/LooseEndCommandsTests.swift`.
- Extend `Tests/PensieveKitTests/LooseEndQueriesTests.swift` (or create if absent).

**PensieveApp (thin)**
- Modify `Sources/PensieveApp/LooseEndRow.swift` — 👍/👎 buttons + suggestion pre-highlight + local optimistic state.
- Modify `Sources/PensieveApp/DetailView.swift`, `Sources/PensieveApp/ContentListView.swift` — pass the label callback.
- Modify `Sources/PensieveApp/AppModel.swift` — `setLooseEndLabel` thin writer.
- Modify `Sources/PensieveApp/Localizable.xcstrings` — accessibility-label keys.

**Operational (NOT committed)**
- One-off throwaway `claude -p` script filling `labelSuggestion` over the open backlog (run at the end).

---

## Task 1: Migration v11 + `LooseEnd.label`/`labelSuggestion` + `LooseEndLabel`

**Files:**
- Modify: `Sources/PensieveKit/Model/LooseEnd.swift`
- Modify: `Sources/PensieveKit/Store/CanonicalStore.swift:143-147` (after the `v10-event-worksummary` block, before `try migrator.migrate(db)`)
- Create: `Sources/PensieveKit/Query/LooseEndCommands.swift` (the `LooseEndLabel` enum only in this task)
- Test: `Tests/PensieveKitTests/SchemaV11Tests.swift`

**Interfaces:**
- Produces: `LooseEnd.label: String`, `LooseEnd.labelSuggestion: String` (canonical columns, `NOT NULL DEFAULT ''`); `LooseEndLabel.salient` / `.noise` / `.unlabeled`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/SchemaV11Tests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func v11AddsLabelColumnsDefaultingToEmpty() throws {
  let db = try openCanonicalDatabase(at: tempURL("v11"))
  let node = Node(name: "Pensieve")
  try db.write { db in try Node.insert { node }.execute(db) }
  let le = LooseEnd(nodeID: node.id, sourceEventID: UUID(), text: "migrate auth later",
                    quote: "we should migrate the auth tables later")
  try db.write { db in try LooseEnd.insert { le }.execute(db) }

  // New rows default to "" (unlabeled), never NULL.
  let stored = try db.read { db in try LooseEnd.where { $0.id.eq(le.id) }.fetchOne(db) }
  #expect(stored?.label == "")
  #expect(stored?.labelSuggestion == "")

  // Values round-trip.
  try db.write { db in
    try LooseEnd.where { $0.id.eq(le.id) }
      .update { $0.label = LooseEndLabel.salient; $0.labelSuggestion = LooseEndLabel.noise }
      .execute(db)
  }
  let updated = try db.read { db in try LooseEnd.where { $0.id.eq(le.id) }.fetchOne(db) }
  #expect(updated?.label == "salient")
  #expect(updated?.labelSuggestion == "noise")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter v11AddsLabelColumnsDefaultingToEmpty`
Expected: FAIL — `LooseEnd` has no member `label` / `LooseEndLabel` undefined (compile error).

- [ ] **Step 3: Add the fields to `LooseEnd`**

In `Sources/PensieveKit/Model/LooseEnd.swift`, add the two stored properties after `sourceMessageIndex` and before `createdAt`, plus init params (defaulted so existing call sites compile). Full struct body:

```swift
@Table
public struct LooseEnd: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var nodeID: UUID
  public var sourceEventID: UUID
  public var text: String        // the open item
  public var quote: String       // verbatim provenance from captured text
  public var status: String      // "open" | "resolved"
  public var role: String            // role of the cited message (e.g. "user")
  public var sourceMessageIndex: Int // index of the cited message within the transcript
  public var label: String           // human-confirmed salience: "" unlabeled | "salient" | "noise"
  public var labelSuggestion: String // machine-suggested salience (same values); never enters the corpus
  public var createdAt: Date
  public init(id: UUID = UUID(), nodeID: UUID, sourceEventID: UUID, text: String,
              quote: String, status: String = "open", role: String = "",
              sourceMessageIndex: Int = 0, label: String = "", labelSuggestion: String = "",
              createdAt: Date = Date()) {
    self.id = id; self.nodeID = nodeID; self.sourceEventID = sourceEventID
    self.text = text; self.quote = quote; self.status = status
    self.role = role; self.sourceMessageIndex = sourceMessageIndex
    self.label = label; self.labelSuggestion = labelSuggestion; self.createdAt = createdAt
  }
}
```

- [ ] **Step 4: Register migration v11**

In `Sources/PensieveKit/Store/CanonicalStore.swift`, add after the `v10-event-worksummary` block (line ~147), before `try migrator.migrate(db)`:

```swift
  migrator.registerMigration("v11-looseend-label") { db in
    // Human-confirmed + machine-suggested salience labels. NOT NULL DEFAULT '' (like v9 context)
    // so `.neq("noise")` filters correctly (a nullable column would drop NULL rows under SQL
    // three-valued logic). Additive; nothing gates on it — Phase 1 stays lossless.
    try #sql(#"ALTER TABLE "looseEnds" ADD COLUMN "label" TEXT NOT NULL DEFAULT ''"#).execute(db)
    try #sql(#"ALTER TABLE "looseEnds" ADD COLUMN "labelSuggestion" TEXT NOT NULL DEFAULT ''"#).execute(db)
  }
```

- [ ] **Step 5: Add the `LooseEndLabel` constants**

Create `Sources/PensieveKit/Query/LooseEndCommands.swift` with just the constants for now (the commands land in Task 2):

```swift
import Foundation
import SQLiteData
import GRDB

/// The `LooseEnd.label` / `.labelSuggestion` string values. Centralized like `NodeContext` /
/// `CaptureKind` so a typo can't silently misfile a label. `""` = unlabeled (the default).
public enum LooseEndLabel {
  public static let unlabeled = ""
  public static let salient = "salient"
  public static let noise = "noise"
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `./scripts/test.sh --filter v11AddsLabelColumnsDefaultingToEmpty`
Expected: PASS.

- [ ] **Step 7: Run the full suite (existing `LooseEnd(...)` call sites compile via defaults)**

Run: `./scripts/test.sh`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveKit/Model/LooseEnd.swift Sources/PensieveKit/Store/CanonicalStore.swift Sources/PensieveKit/Query/LooseEndCommands.swift Tests/PensieveKitTests/SchemaV11Tests.swift
git commit -F - <<'EOF'
feat(kit): add looseEnds.label + labelSuggestion (migration v11)

Human-confirmed and machine-suggested salience labels; NOT NULL DEFAULT ''
(v9 precedent) so .neq("noise") filters correctly. LooseEndLabel constants.
Additive; nothing gates on it — extraction stays lossless.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 2: `LooseEndCommands` (setLabel / suggest / corpus)

**Files:**
- Modify: `Sources/PensieveKit/Query/LooseEndCommands.swift`
- Test: `Tests/PensieveKitTests/LooseEndCommandsTests.swift`

**Interfaces:**
- Consumes: `LooseEnd`, `LooseEndLabel`.
- Produces:
  - `LooseEndCommands.setLabel(_ db: any DatabaseWriter, id: UUID, label: String) throws -> Bool` (human confirm; `label == ""` clears).
  - `LooseEndCommands.suggest(_ db: any DatabaseWriter, id: UUID, label: String) throws -> Bool` (machine suggestion; never touches `label`).
  - `LooseEndCommands.corpus(_ db: any DatabaseReader) throws -> [(quote: String, label: String)]` (confirmed labels only).

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/LooseEndCommandsTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

private func seedLooseEnd(_ db: any DatabaseWriter, quote: String) throws -> UUID {
  let node = Node(name: "N")
  let le = LooseEnd(nodeID: node.id, sourceEventID: UUID(), text: quote, quote: quote)
  try db.write { db in
    try Node.insert { node }.execute(db)
    try LooseEnd.insert { le }.execute(db)
  }
  return le.id
}

@Test func setLabelConfirmsAndClears() throws {
  let db = try openCanonicalDatabase(at: tempURL("cmd-set"))
  let id = try seedLooseEnd(db, quote: "migrate later")
  #expect(try LooseEndCommands.setLabel(db, id: id, label: LooseEndLabel.salient) == true)
  #expect(try db.read { db in try LooseEnd.where { $0.id.eq(id) }.fetchOne(db) }?.label == "salient")
  // "" clears it
  _ = try LooseEndCommands.setLabel(db, id: id, label: LooseEndLabel.unlabeled)
  #expect(try db.read { db in try LooseEnd.where { $0.id.eq(id) }.fetchOne(db) }?.label == "")
}

@Test func setLabelReturnsFalseForUnknownID() throws {
  let db = try openCanonicalDatabase(at: tempURL("cmd-unknown"))
  #expect(try LooseEndCommands.setLabel(db, id: UUID(), label: LooseEndLabel.noise) == false)
}

@Test func suggestNeverTouchesConfirmedLabel() throws {
  let db = try openCanonicalDatabase(at: tempURL("cmd-suggest"))
  let id = try seedLooseEnd(db, quote: "read the spec")
  _ = try LooseEndCommands.suggest(db, id: id, label: LooseEndLabel.noise)
  let row = try db.read { db in try LooseEnd.where { $0.id.eq(id) }.fetchOne(db) }
  #expect(row?.labelSuggestion == "noise")
  #expect(row?.label == "")   // suggestion must not confirm
}

@Test func corpusReturnsOnlyConfirmedLabels() throws {
  let db = try openCanonicalDatabase(at: tempURL("cmd-corpus"))
  let a = try seedLooseEnd(db, quote: "migrate the auth tables later")
  let b = try seedLooseEnd(db, quote: "read the spec now")
  let c = try seedLooseEnd(db, quote: "only suggested, not confirmed")
  _ = try LooseEndCommands.setLabel(db, id: a, label: LooseEndLabel.salient)
  _ = try LooseEndCommands.setLabel(db, id: b, label: LooseEndLabel.noise)
  _ = try LooseEndCommands.suggest(db, id: c, label: LooseEndLabel.salient) // suggestion only -> excluded
  let corpus = try LooseEndCommands.corpus(db)
  #expect(Set(corpus.map { $0.quote }) == ["migrate the auth tables later", "read the spec now"])
  #expect(corpus.first { $0.quote == "migrate the auth tables later" }?.label == "salient")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter LooseEndCommands`
Expected: FAIL — `setLabel`/`suggest`/`corpus` undefined.

- [ ] **Step 3: Implement the commands**

Append to `Sources/PensieveKit/Query/LooseEndCommands.swift` (below the `LooseEndLabel` enum):

```swift

/// The only writer of `LooseEnd.label` / `.labelSuggestion`. `Ingester.drain()` stays the only
/// writer of the rest of a loose end. `label` is set by the user (👍/👎); `labelSuggestion` by a
/// machine (the one-off script now, the trained classifier in Phase 2). The corpus reads confirmed
/// labels only.
public enum LooseEndCommands {
  /// Confirm the user's label. `label == ""` clears it. Returns false (writing nothing) if unknown.
  @discardableResult
  public static func setLabel(_ db: any DatabaseWriter, id: UUID, label: String) throws -> Bool {
    try db.write { db in
      guard try LooseEnd.where({ $0.id.eq(id) }).fetchOne(db) != nil else { return false }
      try LooseEnd.where { $0.id.eq(id) }.update { $0.label = label }.execute(db)
      return true
    }
  }

  /// Record a machine suggestion. Never touches the confirmed `label`. Returns false if unknown.
  @discardableResult
  public static func suggest(_ db: any DatabaseWriter, id: UUID, label: String) throws -> Bool {
    try db.write { db in
      guard try LooseEnd.where({ $0.id.eq(id) }).fetchOne(db) != nil else { return false }
      try LooseEnd.where { $0.id.eq(id) }.update { $0.labelSuggestion = label }.execute(db)
      return true
    }
  }

  /// The confirmed training corpus: every loose end the user has labeled (`label != ""`).
  /// `labelSuggestion` is deliberately NOT read — unaudited machine guesses never enter the corpus.
  public static func corpus(_ db: any DatabaseReader) throws -> [(quote: String, label: String)] {
    try db.read { db in
      try LooseEnd.where { $0.label.neq("") }.fetchAll(db).map { ($0.quote, $0.label) }
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter LooseEndCommands`
Expected: PASS (all 4).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/LooseEndCommands.swift Tests/PensieveKitTests/LooseEndCommandsTests.swift
git commit -F - <<'EOF'
feat(kit): add LooseEndCommands (setLabel/suggest/corpus)

Only writer of label/labelSuggestion. setLabel = human confirm (""=clear);
suggest = machine, never touches confirmed label; corpus reads confirmed
labels only (suggestions never enter training data).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 3: Exclude confirmed-noise from the open-loose-end set (all call sites)

**Files:**
- Modify: `Sources/PensieveKit/Query/LooseEndQueries.swift:15,17`
- Modify: `Sources/PensieveKit/Query/MonitorSnapshot.swift:50,77`
- Modify: `Sources/PensieveKit/Query/NodeFacts.swift:40`
- Modify: `Sources/PensieveKit/Query/NextQueries.swift:23`
- Test: `Tests/PensieveKitTests/LooseEndQueriesTests.swift`

**Interfaces:** unchanged signatures; only the predicate changes. `BriefingQueries` inherits via `LooseEndQueries.open`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/LooseEndQueriesTests.swift` (or append if it exists):

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func openExcludesConfirmedNoiseButKeepsSalientUnlabeledAndSuggested() throws {
  let db = try openCanonicalDatabase(at: tempURL("open-filter"))
  let node = Node(name: "N")
  let src = Event(nodeID: node.id, sourceID: UUID(), occurredAt: Date(),
                  kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Event.insert { src }.execute(db)
  }
  func add(_ quote: String, label: String = "", suggestion: String = "") throws -> UUID {
    let le = LooseEnd(nodeID: node.id, sourceEventID: src.id, text: quote, quote: quote,
                      label: label, labelSuggestion: suggestion)
    try db.write { db in try LooseEnd.insert { le }.execute(db) }
    return le.id
  }
  _ = try add("unlabeled item")
  _ = try add("confirmed salient", label: LooseEndLabel.salient)
  _ = try add("confirmed noise", label: LooseEndLabel.noise)               // excluded
  _ = try add("only suggested noise", suggestion: LooseEndLabel.noise)     // kept (suggestion != decision)

  let open = try LooseEndQueries.open(db, nodeID: node.id, now: Date())
  let texts = Set(open.map { $0.looseEnd.text })
  #expect(texts == ["unlabeled item", "confirmed salient", "only suggested noise"])
  #expect(!texts.contains("confirmed noise"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter openExcludesConfirmedNoise`
Expected: FAIL — "confirmed noise" is still returned (no filter yet).

- [ ] **Step 3: Add `.neq("noise")` at each call site**

In `Sources/PensieveKit/Query/LooseEndQueries.swift`, lines 15 and 17:

```swift
        ends = try LooseEnd.where { $0.nodeID.eq(nodeID) && $0.status.eq("open") && $0.label.neq("noise") }.fetchAll(db)
      } else {
        ends = try LooseEnd.where { $0.status.eq("open") && $0.label.neq("noise") }.fetchAll(db)
```

In `Sources/PensieveKit/Query/MonitorSnapshot.swift`, lines 50 and 77 (both are the same expression):

```swift
        try LooseEnd.where { $0.status.eq("open") && $0.label.neq("noise") }.fetchCount(db)
```

In `Sources/PensieveKit/Query/NodeFacts.swift`, line 40:

```swift
    let open = try LooseEnd.where { $0.nodeID.eq(node.id) && $0.status.eq("open") && $0.label.neq("noise") }.fetchCount(db)
```

In `Sources/PensieveKit/Query/NextQueries.swift`, line 23:

```swift
        let open = try LooseEnd.where { $0.nodeID.eq(p.id) && $0.status.eq("open") && $0.label.neq("noise") }.fetchAll(db).count
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter openExcludesConfirmedNoise`
Expected: PASS.

- [ ] **Step 5: Run the full suite (no regressions; existing rows have `label == ""` so all stay open)**

Run: `./scripts/test.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/LooseEndQueries.swift Sources/PensieveKit/Query/MonitorSnapshot.swift Sources/PensieveKit/Query/NodeFacts.swift Sources/PensieveKit/Query/NextQueries.swift Tests/PensieveKitTests/LooseEndQueriesTests.swift
git commit -F - <<'EOF'
feat(kit): open loose end excludes confirmed noise

Redefine open = status open AND label != noise at every read (LooseEndQueries,
MonitorSnapshot, NodeFacts, NextQueries; Briefing inherits via LooseEndQueries).
A merely-suggested noise item stays visible — a suggestion is not a decision.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 4: 👍/👎 on the shared `LooseEndRow` + `AppModel` writer

**Files:**
- Modify: `Sources/PensieveApp/LooseEndRow.swift`
- Modify: `Sources/PensieveApp/DetailView.swift:65`, `Sources/PensieveApp/ContentListView.swift:55`
- Modify: `Sources/PensieveApp/AppModel.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:** app-target only; no unit tests. Relies on `LooseEndCommands.setLabel` (Task 2) and the fields from Task 1.

- [ ] **Step 1: Add the thin writer to `AppModel`**

In `Sources/PensieveApp/AppModel.swift`, add near the other write helpers (e.g. after `looseEnds(forNode:)`, ~line 409). Do NOT call the full `refresh()` — a label write must not refetch the current list mid-interaction (that would yank a 👎'd row out from under the user before the optimistic toggle reads; the row owns its own optimistic state and the item drops out on the next natural reload/navigation):

```swift
  /// Confirm a user salience label for a loose end (👍 salient / 👎 noise / "" clears). Thin over the
  /// tested LooseEndCommands. Best-effort like the other organizing writes (try?); the row reflects
  /// the change optimistically and confirmed-noise drops from the open set on the next reload.
  func setLooseEndLabel(_ looseEndID: UUID, _ label: String) {
    guard let db else { return }
    _ = try? LooseEndCommands.setLabel(db, id: looseEndID, label: label)
  }
```

- [ ] **Step 2: Add the buttons + optimistic state to `LooseEndRow`**

In `Sources/PensieveApp/LooseEndRow.swift`, add an injected callback and local optimistic state, and render the two thumbs in the header `HStack`. Add the stored properties after `loadProvenance`:

```swift
  /// Confirms a salience label for this loose end (👍 salient / 👎 noise / "" clears). Pass
  /// `model.setLooseEndLabel`.
  let onLabel: (UUID, String) -> Void

  /// Optimistic override of the confirmed label so a tap reflects immediately (the injected
  /// `LooseEndView` is an immutable snapshot). nil = show the stored value. The row is filtered out
  /// of the open list on the next reload when confirmed noise.
  @State private var localLabel: String?
```

Replace the header `HStack` (the `Button { expanded.toggle() } label: { HStack … }` block) so the thumbs sit trailing, and add a computed current-label + a thumbs view. Insert this computed property and view builder in the struct:

```swift
  /// The label to display: the optimistic local value if the user just tapped, else the stored one.
  private var currentLabel: String { localLabel ?? view.looseEnd.label }

  @ViewBuilder private var thumbs: some View {
    HStack(spacing: 10) {
      thumb(systemFilled: "hand.thumbsup.fill", systemOutline: "hand.thumbsup",
            value: LooseEndLabel.salient, help: String(localized: "Mark as a real loose end"))
      thumb(systemFilled: "hand.thumbsdown.fill", systemOutline: "hand.thumbsdown",
            value: LooseEndLabel.noise, help: String(localized: "Mark as not a loose end"))
    }
    .font(.caption)
  }

  /// One thumb. Filled when the confirmed label matches; a faint pre-highlight when only SUGGESTED
  /// (guess awaiting confirm). Tapping toggles: tap the active label again to clear it.
  @ViewBuilder private func thumb(systemFilled: String, systemOutline: String,
                                  value: String, help: String) -> some View {
    let confirmed = currentLabel == value
    let suggested = currentLabel.isEmpty && view.looseEnd.labelSuggestion == value
    Button {
      let next = confirmed ? LooseEndLabel.unlabeled : value
      localLabel = next
      onLabel(view.looseEnd.id, next)
    } label: {
      Image(systemName: confirmed ? systemFilled : systemOutline)
        .foregroundStyle(confirmed ? Color.accentColor : (suggested ? Color.accentColor.opacity(0.55) : Color.secondary))
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
  }
```

Then add `thumbs` to the header row `HStack` (the label of the expand `Button`), before/after the trailing `Spacer()`. Because the expand control is itself a `Button`, place `thumbs` OUTSIDE that button so its taps aren't swallowed — restructure the header as an `HStack` containing the expand `Button` (with the chevron + text) then `Spacer()` then `thumbs`:

```swift
      HStack(spacing: 6) {
        Button {
          expanded.toggle()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.caption2).foregroundStyle(.secondary)
            Text(view.looseEnd.text).prose()
          }
        }
        .buttonStyle(.plain)
        Spacer()
        thumbs
      }
```

- [ ] **Step 3: Pass the callback at both call sites**

In `Sources/PensieveApp/DetailView.swift:65` and `Sources/PensieveApp/ContentListView.swift:55`, change:

```swift
        LooseEndRow(view: view, loadProvenance: model.provenance, onLabel: model.setLooseEndLabel)
```

- [ ] **Step 4: Add the localized strings**

In `Sources/PensieveApp/Localizable.xcstrings`, hand-add two keys, English base + German `de` (`state: "translated"`), matching the catalog's existing entry shape (do NOT rely on xcodebuild to populate):
- `"Mark as a real loose end"` → de `"Als echten losen Faden markieren"`
- `"Mark as not a loose end"` → de `"Als keinen losen Faden markieren"`

- [ ] **Step 5: Build the app**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: BUILD SUCCEEDED. Discard any transient `Package.resolved` churn afterward.

- [ ] **Step 6: Smoke-launch (non-blocking, throwaway store)**

Run:
```bash
PENSIEVE_DB=/tmp/pv-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-smoke-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 4; kill $PID
```
Expected: launches and exits cleanly. (Human eyeball on the real store: each loose end shows 👍/👎; a 👎'd item drops out on reload; a suggested item shows a faint pre-highlighted thumb.)

- [ ] **Step 7: Verify German**

Run `plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -i "loose"` — confirm both German strings are present.

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveApp/LooseEndRow.swift Sources/PensieveApp/DetailView.swift Sources/PensieveApp/ContentListView.swift Sources/PensieveApp/AppModel.swift Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(app): 👍/👎 salience labeling on loose-end rows

Per-item thumbs on the shared LooseEndRow (confirmed = filled, suggested =
faint pre-highlight); optimistic local state; thin AppModel.setLooseEndLabel
over LooseEndCommands. Confirmed-noise drops from the open set on reload.
EN + DE accessibility labels.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 5: One-off Haiku suggestion pass (throwaway, NOT committed)

> Run once, by hand, after Tasks 1-4 are merged and the app can display suggestions. Populates
> `labelSuggestion` over the open backlog so the user confirms/flips a pre-highlighted guess instead
> of labeling from scratch. NOT a committed CLI — a throwaway script, like the eval sampler.
> **Writes only `labelSuggestion` (additive, non-destructive); back up the store first anyway.**

- [ ] **Step 1: Back up the live store**

```bash
cp ~/Library/Application\ Support/Pensieve/pensieve.sqlite /tmp/pensieve.backup.$(date +%s).sqlite
```

- [ ] **Step 2: Run a throwaway suggestion script**

Reuse the salience prompt + `claude -p --model claude-haiku-4-5-20251001` (recall 0.947 — a good suggester, per `docs/superpowers/salience-eval-2026-07-09.md`) over each open loose end and write `labelSuggestion` via `LooseEndCommands.suggest` (or a direct `sqlite3 UPDATE`). The exact script form (throwaway bash+sqlite3+claude, or a throwaway Swift entry reusing `SalienceClassifier`) is decided at run time; it is NOT committed. It must set `labelSuggestion` only, never `label`.

- [ ] **Step 3: Verify + review**

```bash
sqlite3 ~/Library/Application\ Support/Pensieve/pensieve.sqlite \
  "SELECT labelSuggestion, COUNT(*) FROM looseEnds WHERE status='open' GROUP BY labelSuggestion;"
```
Then open the app and confirm/flip the pre-highlighted thumbs. Confirmed labels (not suggestions) become the corpus.

---

## Final verification (whole branch)

- [ ] **Full Kit suite green**

Run: `./scripts/test.sh`
Expected: PASS (all prior tests + the new SchemaV11 / LooseEndCommands / LooseEndQueries tests).

- [ ] **App builds + smoke-launches**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
PENSIEVE_DB=/tmp/pv-final.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-final-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve & PID=$!; sleep 4; kill $PID
```
Expected: BUILD SUCCEEDED + clean launch/exit.

- [ ] **Whole-branch review** via `superpowers:requesting-code-review` (Opus), then `superpowers:finishing-a-development-branch`.
