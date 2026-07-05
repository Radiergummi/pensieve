# Pensieve.app Slice 2 — Briefing Home + ⌘K Palette — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the two remaining "doors" onto the slice-1 recall view: a **Briefing** home screen (the default landing — a by-project "what moved since you last looked" world map) and a **⌘K command palette** that fuzzy-jumps to any project/strand/smart-list/Briefing.

**Architecture:** Derivation stays in tested `PensieveKit` (`BriefingQueries` builds the per-project cards); the SwiftUI layer is thin. "Since last visit" is a persisted `lastOpenedAt` timestamp in `UserDefaults` (app-only, never touches the canonical store). The palette is navigation-only (the app is still read-only until slice 4) and reuses the existing selection state.

**Tech Stack:** Swift 6, SwiftUI + AppKit host, SQLiteData (GRDB-backed), Swift Testing.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-05-pensieve-app-three-pane-design.md` (slice 2 of its build sequence).
- **Run tests with `./scripts/test.sh`** (optionally `--filter <name>`) — **never** plain `swift test`. `swift build` / `swift run` work normally.
- **SQLiteData predicates use `.eq(x)`, NOT `== x`.**
- **Reads only touch the canonical store; the app never writes canonical rows** except via the existing `Ingester.drain()`. "Since last visit" persistence uses `UserDefaults`, NOT the canonical store.
- **No LLM calls in this slice.** Briefing cards are deterministic (event counts + captured summaries + stored loose-end text).
- **Grounded-only:** a Briefing card only appears for a node that has captured events; "what moved" is a real event count, "top next" is a real open loose-end's text.
- **⌘K is navigation-only** in this slice (jump to a node / smart list / Briefing). No actions, no writes.
- App-target code (`PensieveApp`) has no unit tests — verify with `swift build` + a non-blocking smoke-launch. `PensieveKit` code is TDD'd.
- **No Python, ever. Swift only.**

## File Structure

**Create:**
- `Sources/PensieveKit/Query/BriefingQueries.swift` — `BriefingCard` + `BriefingQueries.cards(_:since:now:)`: per-active-project card (moved-since count, latest summary, open loose-end count + top loose-end text, days dormant). Tested.
- `Sources/PensieveApp/BriefingView.swift` — the by-project world-map detail view (default landing).
- `Sources/PensieveApp/PaletteView.swift` — the ⌘K command palette sheet.
- `Tests/PensieveKitTests/BriefingQueriesTests.swift`

**Modify:**
- `Sources/PensieveApp/AppModel.swift` — add `.briefing` to `SidebarSelection`; default landing; `lastOpenedAt` persistence + `briefingSince`; `@Published briefingCards`; `.briefing` in `nodesForSelection()`; `matchingNodes(_:)` + palette destinations.
- `Sources/PensieveApp/SidebarView.swift` — a pinned "Briefing" row above Smart Lists.
- `Sources/PensieveApp/RootView.swift` — detail shows `BriefingView` when `.briefing` is selected; ⌘K trigger + palette sheet.

---

### Task 1: `BriefingQueries` — per-project "since last visit" cards

**Files:**
- Create: `Sources/PensieveKit/Query/BriefingQueries.swift`
- Test: `Tests/PensieveKitTests/BriefingQueriesTests.swift`

**Interfaces:**
- Consumes: `Node` (`id`, `name`, `state`), `Event` (`nodeID`, `occurredAt`, `summary`), `LooseEndQueries.open(_:nodeID:now:) -> [LooseEndView]` (`LooseEndView.looseEnd.text`).
- Produces:
  - `struct BriefingCard: Sendable, Identifiable { let node: Node; let movedSince: Int; let latestSummary: String; let openLooseEnds: Int; let topLooseEnd: String?; let daysDormant: Int; var id: UUID { node.id } }`
  - `enum BriefingQueries { static func cards(_ db: any DatabaseWriter, since: Date, now: Date) throws -> [BriefingCard] }`
  - Contract: one card per **active** node (`state == "active"`) that has at least one event (no events → skipped, nothing grounded). `movedSince` = count of that node's events with `occurredAt > since`. `latestSummary` = the most-recent event's `summary`. `openLooseEnds` = count of open loose ends; `topLooseEnd` = the oldest-sourced open loose end's `text` (or nil). `daysDormant` = whole days from the latest event to `now`. Sorted: nodes that moved first (`movedSince` desc), then the rest by `daysDormant` asc.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/BriefingQueriesTests.swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func cardsSplitMovedFromQuietAndCarryLooseEnds() throws {
  let db = try openCanonicalDatabase(at: tempURL("briefing"))
  let resolver = ProjectResolver(db: db)
  let (moved, ms) = try resolver.resolve(path: "/p/moved", kind: SourceKind.claudeCode)
  let (quiet, qs) = try resolver.resolve(path: "/p/quiet", kind: SourceKind.claudeCode)
  let now = Date()
  let since = Calendar.current.date(byAdding: .day, value: -2, to: now)!   // "last visit" = 2 days ago
  let recent = Calendar.current.date(byAdding: .day, value: -1, to: now)!  // after `since`
  let old = Calendar.current.date(byAdding: .day, value: -10, to: now)!    // before `since`
  try db.write { db in
    let e1 = Event(nodeID: moved.id, sourceID: ms.id, occurredAt: recent, kind: CaptureKind.ccSession,
                   summary: "shipped the thing", detailJSON: "{}", fingerprint: "m1")
    try Event.insert { e1 }.execute(db)
    try LooseEnd.insert {
      LooseEnd(nodeID: moved.id, sourceEventID: e1.id, text: "rotate CI keys", quote: "set CI vars",
               role: "user", sourceMessageIndex: 0)
    }.execute(db)
    try Event.insert {
      Event(nodeID: quiet.id, sourceID: qs.id, occurredAt: old, kind: CaptureKind.ccSession,
            summary: "old work", detailJSON: "{}", fingerprint: "q1")
    }.execute(db)
  }

  let cards = try BriefingQueries.cards(db, since: since, now: now)

  #expect(cards.count == 2)
  #expect(cards.first?.node.id == moved.id)            // moved sorts before quiet
  let movedCard = try #require(cards.first)
  #expect(movedCard.movedSince == 1)
  #expect(movedCard.latestSummary == "shipped the thing")
  #expect(movedCard.openLooseEnds == 1)
  #expect(movedCard.topLooseEnd == "rotate CI keys")
  let quietCard = try #require(cards.last)
  #expect(quietCard.movedSince == 0)                   // its only event predates `since`
  #expect(quietCard.topLooseEnd == nil)
}

@Test func nodeWithNoEventsIsSkipped() throws {
  let db = try openCanonicalDatabase(at: tempURL("briefing-empty"))
  let resolver = ProjectResolver(db: db)
  _ = try resolver.resolve(path: "/p/untouched", kind: SourceKind.claudeCode)
  let cards = try BriefingQueries.cards(db, since: Date.distantPast, now: Date())
  #expect(cards.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter BriefingQueries`
Expected: FAIL — `cannot find 'BriefingQueries' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PensieveKit/Query/BriefingQueries.swift
import Foundation
import SQLiteData

/// One active project's line in the Briefing home: what moved since the last visit, plus its
/// single most-outstanding open loose end. Deterministic; grounded in captured rows.
public struct BriefingCard: Sendable, Identifiable {
  public let node: Node
  public let movedSince: Int        // events with occurredAt > since
  public let latestSummary: String  // most-recent event's summary ("" if none — never happens for a card)
  public let openLooseEnds: Int
  public let topLooseEnd: String?   // oldest-sourced open loose end's text
  public let daysDormant: Int
  public var id: UUID { node.id }

  public init(node: Node, movedSince: Int, latestSummary: String,
              openLooseEnds: Int, topLooseEnd: String?, daysDormant: Int) {
    self.node = node; self.movedSince = movedSince; self.latestSummary = latestSummary
    self.openLooseEnds = openLooseEnds; self.topLooseEnd = topLooseEnd; self.daysDormant = daysDormant
  }
}

public enum BriefingQueries {
  public static func cards(_ db: any DatabaseWriter, since: Date, now: Date) throws -> [BriefingCard] {
    try db.read { db in
      let actives = try Node.where { $0.state.eq("active") }.fetchAll(db)
      var cards: [BriefingCard] = []
      for node in actives {
        let events = try Event.where { $0.nodeID.eq(node.id) }
          .order { $0.occurredAt.desc() }.fetchAll(db)
        guard let latest = events.first else { continue }   // no captured activity → nothing grounded
        let moved = events.filter { $0.occurredAt > since }.count
        let dormant = Calendar.current.dateComponents([.day], from: latest.occurredAt, to: now).day ?? 0
        let ends = try LooseEndQueries.open(db, nodeID: node.id, now: now)
        cards.append(BriefingCard(
          node: node, movedSince: moved, latestSummary: latest.summary,
          openLooseEnds: ends.count, topLooseEnd: ends.first?.looseEnd.text, daysDormant: dormant))
      }
      // Moved-since-last-visit first (most movement first); then the quiet ones, least-dormant first.
      return cards.sorted {
        $0.movedSince != $1.movedSince ? $0.movedSince > $1.movedSince : $0.daysDormant < $1.daysDormant
      }
    }
  }
}
```

Note: `LooseEndQueries.open` takes `any DatabaseWriter` and opens its own `db.read`; here we call it from inside a `db.read` on the same pool. GRDB pools allow concurrent reads, so this is safe — but if it deadlocks or double-reads awkwardly, hoist the loose-end fetch out: collect nodes first, then fetch ends per node after the `db.read` block. Prefer the inline form unless a test shows a problem.

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter BriefingQueries`
Expected: PASS (2 tests). If the inline `LooseEndQueries.open` call deadlocks the pool, refactor as the note describes and re-run.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/BriefingQueries.swift Tests/PensieveKitTests/BriefingQueriesTests.swift
git commit -m "feat: BriefingQueries — per-project since-last-visit cards"
```

---

### Task 2: `AppModel` — Briefing state, last-visit persistence, palette data

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift`

**Interfaces:**
- Consumes: `BriefingQueries.cards(_:since:now:) -> [BriefingCard]`, `BriefingCard`.
- Produces (used by Tasks 3–4):
  - `SidebarSelection` gains `case briefing`.
  - `AppModel.sidebarSelection` default is now `.briefing`.
  - `@Published var briefingCards: [BriefingCard]`, `let briefingSince: Date`.
  - `nodesForSelection()` returns `briefingCards.map(\.node)` for `.briefing`.
  - `func matchingNodes(_ query: String) -> [Node]` — case-insensitive name substring over all nodes (empty query → all).
  - `enum PaletteDestination: Hashable { case node(UUID); case smartList(SmartListKind); case briefing }` with `func apply(to model: AppModel)`.

- [ ] **Step 1: Add `.briefing` to `SidebarSelection` and make it the default**

In `Sources/PensieveApp/AppModel.swift`, change the `SidebarSelection` enum and the `sidebarSelection` default:

```swift
enum SidebarSelection: Hashable {
  case briefing
  case smartList(SmartListKind)
  case node(UUID)
}
```

```swift
  @Published var sidebarSelection: SidebarSelection? = .briefing
```

- [ ] **Step 2: Add Briefing state + last-visit persistence**

Add these stored properties to `AppModel` (next to the other `@Published`s):

```swift
  @Published var briefingCards: [BriefingCard] = []
  /// "Since when" the Briefing measures movement: the previous launch's timestamp (or 7 days ago on
  /// first run). Fixed for the session so cards don't shift under you while the window is open.
  let briefingSince: Date
```

Add an initializer that reads-then-updates the persisted timestamp (place above `start()`):

```swift
  private static let lastOpenedKey = "pensieve.lastOpenedAt"

  init() {
    let prev = UserDefaults.standard.object(forKey: Self.lastOpenedKey) as? Date
    briefingSince = prev ?? Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    UserDefaults.standard.set(Date(), forKey: Self.lastOpenedKey)
  }
```

- [ ] **Step 3: Compute cards in `refresh()`**

In `refresh()`, after the `lists = …` line and inside the `guard let db` scope, add the cards computation:

```swift
    briefingCards = (try? BriefingQueries.cards(db, since: briefingSince, now: now)) ?? briefingCards
```

(Place it after `lists = (try? SmartLists.compute(db, now: now)) ?? lists` and before the forest block.)

- [ ] **Step 4: Handle `.briefing` in `nodesForSelection()` and add palette helpers**

In `nodesForSelection()`, add the `.briefing` case at the top of the switch:

```swift
    case .briefing:
      return briefingCards.map(\.node)
```

Add these methods to `AppModel` (after `nodesForSelection()`):

```swift
  /// Nodes whose name contains `query` (case-insensitive); empty query returns all. For ⌘K.
  func matchingNodes(_ query: String) -> [Node] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return allNodes }
    return allNodes.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
  }
```

Add the palette destination type at file scope (below `SidebarSelection`):

```swift
/// A ⌘K jump target. Navigation only — sets the same selection state the sidebar does.
enum PaletteDestination: Hashable {
  case node(UUID)
  case smartList(SmartListKind)
  case briefing

  @MainActor func apply(to model: AppModel) {
    switch self {
    case .node(let id):
      model.sidebarSelection = .node(id); model.selectedNodeID = id
    case .smartList(let kind):
      model.sidebarSelection = .smartList(kind); model.selectedNodeID = nil
    case .briefing:
      model.sidebarSelection = .briefing; model.selectedNodeID = nil
    }
  }
}
```

- [ ] **Step 5: Build + smoke-launch**

Run: `swift build`
Expected: builds cleanly.

Run (non-blocking, throwaway store):
```
PENSIEVE_DB=/tmp/pensieve-smoke-$$.sqlite PENSIEVE_CAPTURE_DB=/tmp/pensieve-smoke-spool-$$.sqlite \
  swift run PensieveApp >/tmp/pensieve-smoke-$$.log 2>&1 &
PID=$!; sleep 6; if kill -0 $PID 2>/dev/null; then echo "LAUNCH OK"; kill $PID; else echo "CRASHED"; cat /tmp/pensieve-smoke-$$.log; fi
```
Expected: LAUNCH OK (empty store → empty Briefing, no crash). Background + kill; never foreground `swift run`.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift
git commit -m "feat: AppModel briefing state + last-visit persistence + palette destinations"
```

---

### Task 3: `BriefingView` + sidebar row + default landing

**Files:**
- Create: `Sources/PensieveApp/BriefingView.swift`
- Modify: `Sources/PensieveApp/SidebarView.swift` (pinned Briefing row)
- Modify: `Sources/PensieveApp/RootView.swift` (show `BriefingView` in detail)

**Interfaces:**
- Consumes: `AppModel.briefingCards` (`[BriefingCard]`), `AppModel.briefingSince`, `AppModel.selectedNodeID`, `AppModel.sidebarSelection`, `BriefingCard`, `SidebarSelection.briefing`.

- [ ] **Step 1: Write `BriefingView`**

```swift
// Sources/PensieveApp/BriefingView.swift
import SwiftUI
import PensieveKit

/// The default landing: a by-project "world map" — what moved since your last visit, and each
/// project's most-outstanding loose end. Clicking a card drills into that project's detail.
struct BriefingView: View {
  @ObservedObject var model: AppModel

  private var moved: [BriefingCard] { model.briefingCards.filter { $0.movedSince > 0 } }
  private var quiet: [BriefingCard] { model.briefingCards.filter { $0.movedSince == 0 } }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Since \(model.briefingSince, format: .dateTime.weekday(.wide).month().day())")
          .font(.largeTitle).bold()

        if model.briefingCards.isEmpty {
          Text("No captured activity yet.").foregroundStyle(.secondary)
        }

        if !moved.isEmpty {
          section("Moved") { ForEach(moved) { card(for: $0) } }
        }
        if !quiet.isEmpty {
          section("Quiet") { ForEach(quiet) { card(for: $0) } }
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func card(for c: BriefingCard) -> some View {
    Button { model.selectedNodeID = c.node.id } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(c.node.name).font(.headline)
          Spacer()
          if c.movedSince > 0 {
            Text("\(c.movedSince) since last visit").font(.caption).foregroundStyle(.secondary)
          } else {
            Text("dormant \(c.daysDormant)d").font(.caption).foregroundStyle(.tertiary)
          }
        }
        if !c.latestSummary.isEmpty {
          Text(c.latestSummary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        if let top = c.topLooseEnd {
          Label(top, systemImage: "arrow.right.circle").font(.caption).foregroundStyle(.orange).lineLimit(1)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
      content()
    }
  }
}
```

- [ ] **Step 2: Add the pinned Briefing row to the sidebar**

In `Sources/PensieveApp/SidebarView.swift`, add a Briefing row as the FIRST item in the `List` (above the `Section("Smart Lists")`):

```swift
      Label("Briefing", systemImage: "sun.max")
        .tag(SidebarSelection.briefing)
      Section("Smart Lists") {
```

(Insert the two `Label`/tag lines immediately after the `List(selection:) { ... }` opening `{`, before `Section("Smart Lists")`.)

- [ ] **Step 3: Show `BriefingView` in the detail column**

In `Sources/PensieveApp/RootView.swift`, replace the `detail:` closure body:

```swift
    } detail: {
      if let id = model.selectedNodeID, let node = model.node(id) {
        DetailView(model: model, node: node)
      } else if model.sidebarSelection == .briefing {
        BriefingView(model: model)
      } else {
        ContentUnavailableView("Select a project", systemImage: "sidebar.left")
      }
    }
```

- [ ] **Step 4: Build + smoke-launch, then a real visual check**

Run: `swift build`
Expected: builds cleanly.

Run the throwaway-store smoke (as in Task 2, Step 5) → expect LAUNCH OK.

Then a real look (opens a window on screen; drains the real spool — harmless):
```
swift run PensieveApp >/tmp/pensieve-real.log 2>&1 &
```
Expected: launches on the **Briefing** screen showing per-project cards under "Moved"/"Quiet"; clicking a card switches the detail to that project. Close the window (or `kill %1`) when done. (Visual confirmation is a human step; the automated gate is `swift build` + smoke.)

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/BriefingView.swift Sources/PensieveApp/SidebarView.swift Sources/PensieveApp/RootView.swift
git commit -m "feat: Briefing home — by-project world map as the default landing"
```

---

### Task 4: ⌘K command palette (navigation-only)

**Files:**
- Create: `Sources/PensieveApp/PaletteView.swift`
- Modify: `Sources/PensieveApp/RootView.swift` (⌘K trigger + sheet)

**Interfaces:**
- Consumes: `AppModel.matchingNodes(_:)`, `AppModel.briefingCards`, `SmartListKind.allCases`/`.title`, `PaletteDestination`, `Node`.

- [ ] **Step 1: Write `PaletteView`**

```swift
// Sources/PensieveApp/PaletteView.swift
import SwiftUI
import PensieveKit

/// ⌘K fuzzy-jump. Navigation only: pick a destination and it sets the sidebar/detail selection.
struct PaletteView: View {
  @ObservedObject var model: AppModel
  @Binding var isPresented: Bool
  @State private var query = ""
  @FocusState private var focused: Bool

  private struct Row: Identifiable {
    let id: String
    let label: String
    let systemImage: String
    let destination: PaletteDestination
  }

  private var rows: [Row] {
    var out: [Row] = []
    let q = query.trimmingCharacters(in: .whitespaces)
    // Destinations (Briefing + smart lists) — shown when they match the query (or query is empty).
    func matches(_ s: String) -> Bool { q.isEmpty || s.range(of: q, options: .caseInsensitive) != nil }
    if matches("Briefing") {
      out.append(Row(id: "briefing", label: "Briefing", systemImage: "sun.max", destination: .briefing))
    }
    for kind in SmartListKind.allCases where matches(kind.title) {
      out.append(Row(id: "sl-\(kind.rawValue)", label: kind.title, systemImage: kind.symbol,
                     destination: .smartList(kind)))
    }
    for node in model.matchingNodes(q).prefix(20) {
      out.append(Row(id: "n-\(node.id)", label: node.name, systemImage: "shippingbox",
                     destination: .node(node.id)))
    }
    return out
  }

  var body: some View {
    VStack(spacing: 0) {
      TextField("Jump to…", text: $query)
        .textFieldStyle(.plain)
        .font(.title3)
        .padding(12)
        .focused($focused)
        .onSubmit { select(rows.first) }        // Enter jumps to the top match
      Divider()
      List(rows) { row in
        Button { select(row) } label: {
          Label(row.label, systemImage: row.systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
      }
      .frame(height: 320)
    }
    .frame(width: 480)
    .onAppear { focused = true }
  }

  private func select(_ row: Row?) {
    guard let row else { return }
    row.destination.apply(to: model)
    isPresented = false
  }
}
```

- [ ] **Step 2: Add the ⌘K trigger + sheet to `RootView`**

In `Sources/PensieveApp/RootView.swift`, add the palette state and wire it. Change `RootView` to:

```swift
struct RootView: View {
  @ObservedObject var model: AppModel
  @State private var showPalette = false

  var body: some View {
    NavigationSplitView {
      SidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    } content: {
      ContentListView(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
    } detail: {
      if let id = model.selectedNodeID, let node = model.node(id) {
        DetailView(model: model, node: node)
      } else if model.sidebarSelection == .briefing {
        BriefingView(model: model)
      } else {
        ContentUnavailableView("Select a project", systemImage: "sidebar.left")
      }
    }
    .navigationTitle("Pensieve")
    // A hidden, zero-size button carries the ⌘K shortcut for the key window.
    .background {
      Button("") { showPalette = true }
        .keyboardShortcut("k", modifiers: .command)
        .opacity(0)
        .accessibilityHidden(true)
    }
    .sheet(isPresented: $showPalette) {
      PaletteView(model: model, isPresented: $showPalette)
    }
  }
}
```

- [ ] **Step 3: Build + smoke-launch, then a real ⌘K check**

Run: `swift build`
Expected: builds cleanly.

Run the throwaway-store smoke (as before) → expect LAUNCH OK.

Then a real look:
```
swift run PensieveApp >/tmp/pensieve-real.log 2>&1 &
```
Expected: pressing **⌘K** opens the palette; typing filters projects/strands + Briefing + smart lists; Enter jumps to the top match and closes the palette; clicking a row jumps to it. Close the window when done. (Visual/interaction confirmation is a human step; the automated gate is `swift build` + smoke.)

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/PaletteView.swift Sources/PensieveApp/RootView.swift
git commit -m "feat: ⌘K command palette — navigation-only fuzzy jump"
```

---

## Self-Review

**Spec coverage (slice 2 bullets):**
- Briefing as the default landing (by-project world map) → Tasks 1–3. ✓
- "What moved since last visit" via persisted `lastOpenedAt` → Task 2 (`init`, `briefingSince`) + Task 1 (`movedSince`). ✓ (UserDefaults, not the canonical store — per Global Constraints.)
- Dormant/quiet collapsed below → Task 3 (`moved`/`quiet` sections). ✓
- ⌘K command palette, jump to project/strand/smart-list/Briefing → Task 4 + `PaletteDestination` (Task 2). ✓ Navigation-only. ✓
- Grounded/deterministic, no LLM → Task 1 (cards from real events + loose-end text). ✓

**Placeholder scan:** none — every step has complete code or an exact command.

**Type consistency:** `BriefingCard` fields (`node`/`movedSince`/`latestSummary`/`openLooseEnds`/`topLooseEnd`/`daysDormant`/`id`) are used identically in Tasks 1 & 3. `SidebarSelection.briefing`, `PaletteDestination`, `AppModel.briefingCards`/`briefingSince`/`matchingNodes` are defined in Task 2 and consumed with matching signatures in Tasks 3–4. `SmartListKind.allCases`/`.title`/`.symbol`/`.rawValue` already exist from slice 1.

**Deferred (not gaps):** palette arrow-key navigation (Enter-selects-top-match + click suffice for slice 2); Briefing auto-refresh of `briefingSince` mid-session (fixed per session by design); window/inspector polish and LLM narration (slice 3).

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-05-pensieve-app-slice2-briefing-palette.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
