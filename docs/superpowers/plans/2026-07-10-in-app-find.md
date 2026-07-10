# In-app Find (search captured content) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native in-app search that finds any node or open loose end by a phrase from its text or cited quote, and lands the user on the exact item — honoring the active Focus filter and the grounded-with-provenance north star.

**Architecture:** One tested PensieveKit kernel (`SnippetMaker` + `SearchQueries`, read-only, pure over its inputs) plus a thin SwiftUI layer: a native `.searchable` field whose results render in the content column and drive selection. Mirrors the existing `NextQueries`/`LooseEndQueries` kernels and the `provenance(for:)` off-main read.

**Tech Stack:** Swift 6, SQLiteData (GRDB), SwiftUI, Swift Testing (`@Test`), XcodeGen + Xcode 26.6.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-10-in-app-find-design.md` (all requirements below trace to it).
- **SQLiteData predicates use `.eq(x)`/`.neq(x)`, never `== x`** (won't compile).
- **No FTS5, no embeddings, no schema/migration change.** Read-only over existing tables. (Vectors are sub-project #2.)
- **Kernel takes `_ db: any DatabaseReader` and owns its `db.read { }`** — matches every sibling kernel; the off-main precedent is `AppModel.provenance(for:)` (a `Task.detached` capturing the `DatabaseWriter`), **not** `SummaryBuilder.narrate` (touches no DB).
- **CRITICAL — do NOT delete `PaletteDestination`, `.apply(to:)`, or `DeepLinkNavigation`/`applyDeepLink`.** Despite the "quick-jump destination" name they are the shared navigation-apply core for `pensieve://` deep links, App Intents, and the menu-bar popover. Removing the palette means removing ONLY: `AppModel.showPalette`, `PaletteView.swift`, `AppModel.matchingNodes(_:)`, the `Go ▸ Quick Jump` command, and the `"Quick Jump…"`/`"Jump to…"` String Catalog keys.
- **Grounded core corpus only:** node `name` + `description`, loose-end `text` + `quote`. No event/narration text. Loose ends filtered by the shared `LooseEnd.isOpen` predicate (open + not user-labeled noise).
- **Deterministic ranking:** every sort ends in a total tiebreaker on `id.uuidString`. Per-section cap = `prefix(50)` **after** sorting; `total*Matches` carry pre-cap counts.
- **Min query length 2 graphemes** (`trimmed.count`, not `.utf16.count`).
- **Content vs chrome (localization):** chrome is localized to German; node names, loose-end `text`, and `quote` are **content — never localized**. Xcode does NOT auto-populate `Localizable.xcstrings` on a command-line build — author/reconcile keys by hand.
- **The app target has no unit tests.** Verify app tasks by building via Xcode and a non-blocking smoke-launch of the inner binary with throwaway stores:
  ```
  xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
  ```
  Then, background + `kill`, forwarding throwaway env:
  ```
  PENSIEVE_DB=/tmp/find-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/find-smoke-cap.sqlite ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
  sleep 4; kill %1
  ```
  **Never set `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` toward the live store.** Kit tasks (1–2) use `./scripts/test.sh`.
- **Planning refinements (deviations from the spec, applied deliberately — surface to the user):**
  1. A search-result tap sets **`selectedNodeID` only** (the established briefing-card pattern), NOT `sidebarSelection`. This keeps clearing-the-field coherent without a `.onChange(of: sidebarSelection)` race against "sidebar nav clears search."
  2. Find is bound to native **⌘F** only; the old **⌘K** binding is dropped (two menu items for one action is un-native; ⌘F is the standard Find). Fully satisfies the "kill the anti-pattern popover, go native" intent.

---

### Task 1: `Snippet` + `SnippetMaker` (pure Kit helper)

**Files:**
- Create: `Sources/PensieveKit/Query/Snippet.swift`
- Test: `Tests/PensieveKitTests/SnippetMakerTests.swift`

**Interfaces:**
- Produces:
  - `struct Snippet: Equatable, Sendable { var leading: String; var match: String; var trailing: String }` (+ memberwise `init`)
  - `enum SnippetMaker { static func make(from source: String, matching query: String, window: Int = 80) -> Snippet }`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PensieveKitTests/SnippetMakerTests.swift
import Foundation
import Testing
@testable import PensieveKit

@Test func snippetMatchAtStart() {
  let s = SnippetMaker.make(from: "hello world", matching: "hello")
  #expect(s.leading == "")
  #expect(s.match == "hello")
  #expect(s.trailing == " world")
}

@Test func snippetMatchInMiddle() {
  let s = SnippetMaker.make(from: "the quick brown fox", matching: "quick")
  #expect(s.leading == "the ")
  #expect(s.match == "quick")
  #expect(s.trailing == " brown fox")
}

@Test func snippetMatchAtEnd() {
  let s = SnippetMaker.make(from: "abc xyz", matching: "xyz")
  #expect(s.leading == "abc ")
  #expect(s.match == "xyz")
  #expect(s.trailing == "")
}

@Test func snippetIsCaseInsensitiveAndKeepsSourceCase() {
  let s = SnippetMaker.make(from: "Deploy the App", matching: "deploy")
  #expect(s.match == "Deploy")   // original case preserved
}

@Test func snippetTakesFirstOccurrence() {
  let s = SnippetMaker.make(from: "cat dog cat", matching: "cat")
  #expect(s.leading == "")
  #expect(s.match == "cat")
  #expect(s.trailing == " dog cat")
}

@Test func snippetNoMatchReturnsSourceInLeading() {
  let s = SnippetMaker.make(from: "hello", matching: "zzz")
  #expect(s.leading == "hello")
  #expect(s.match == "")
  #expect(s.trailing == "")
}

@Test func snippetRoundTrips() {
  let s = SnippetMaker.make(from: "the quick brown fox", matching: "quick")
  #expect(s.leading + s.match + s.trailing == "the quick brown fox")
}

@Test func snippetWindowsLongSidesAndKeepsMatchExact() {
  let source = String(repeating: "a", count: 200) + "NEEDLE" + String(repeating: "b", count: 200)
  let s = SnippetMaker.make(from: source, matching: "needle", window: 10)
  #expect(s.match == "NEEDLE")
  #expect(s.leading.hasPrefix("…"))
  #expect(s.trailing.hasSuffix("…"))
  #expect(s.leading.count <= 11)   // "…" + 10
  #expect(s.trailing.count <= 11)
}

@Test func snippetUnicodeSafe() {
  let s = SnippetMaker.make(from: "😀😀 needle 🚀", matching: "needle")
  #expect(s.leading == "😀😀 ")
  #expect(s.match == "needle")
  #expect(s.trailing == " 🚀")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter SnippetMaker`
Expected: FAIL — `cannot find 'SnippetMaker' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/PensieveKit/Query/Snippet.swift
import Foundation

/// A search match split into three runs so a view can render the highlight with ZERO index
/// conversion: `Text(leading) + Text(match).bold() + Text(trailing)`. Sturdier and more testable
/// than a `Range<String.Index>`, and unicode-safe (all splits are on `String.Index`).
public struct Snippet: Equatable, Sendable {
  public var leading: String   // text before the match (may start with "…" when windowed)
  public var match: String     // the matched substring, original case ("" when no match)
  public var trailing: String  // text after the match (may end with "…" when windowed)
  public init(leading: String, match: String, trailing: String) {
    self.leading = leading; self.match = match; self.trailing = trailing
  }
}

public enum SnippetMaker {
  /// Case-insensitive first-occurrence match. Windows each side to `window` characters (adding an
  /// ellipsis when truncated), so `leading + match + trailing` always equals the shown text and
  /// `match` is exactly the matched substring. No match → a head window of the source in `leading`.
  public static func make(from source: String, matching query: String, window: Int = 80) -> Snippet {
    guard let r = source.range(of: query, options: .caseInsensitive) else {
      let head = String(source.prefix(window * 2))
      let lead = head.count < source.count ? head + "…" : head
      return Snippet(leading: lead, match: "", trailing: "")
    }
    let matched = String(source[r])
    var lead = String(source[source.startIndex..<r.lowerBound])
    if lead.count > window { lead = "…" + String(lead.suffix(window)) }
    var trail = String(source[r.upperBound...])
    if trail.count > window { trail = String(trail.prefix(window)) + "…" }
    return Snippet(leading: lead, match: matched, trailing: trail)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter SnippetMaker`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/Snippet.swift Tests/PensieveKitTests/SnippetMakerTests.swift
git commit -F - <<'EOF'
feat(kit): SnippetMaker — grounded (leading, match, trailing) search snippet

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SPid7S4FhCUroJMMmPhFy1
EOF
```

---

### Task 2: `SearchQueries` kernel (Kit, tested)

**Files:**
- Create: `Sources/PensieveKit/Query/SearchQueries.swift`
- Test: `Tests/PensieveKitTests/SearchQueriesTests.swift`

**Interfaces:**
- Consumes: `Snippet`/`SnippetMaker` (Task 1); `Node`, `LooseEnd`, `LooseEnd.isOpen`, `ProjectQueries.all`.
- Produces:
  - `struct SearchResults: Equatable, Sendable { var nodes: [NodeHit]; var looseEnds: [LooseEndHit]; var totalNodeMatches: Int; var totalLooseEndMatches: Int; var isEmpty: Bool }`
  - `struct NodeHit: Identifiable, Equatable, Sendable { let id: UUID; var name: String; var kind: String; var snippet: Snippet }`
  - `struct LooseEndHit: Identifiable, Equatable, Sendable { let id: UUID; var nodeID: UUID; var nodeName: String; var snippet: Snippet }`
  - `enum SearchQueries { static let minQueryLength = 2; static func search(query: String, visibleNodeIDs: Set<UUID>, _ db: any DatabaseReader) throws -> SearchResults }`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PensieveKitTests/SearchQueriesTests.swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// Insert a node + one event + loose ends; returns the node.
private func seed(_ db: any DatabaseWriter, name: String, description: String = "",
                  kind: String = NodeKind.project,
                  ends: [(text: String, quote: String, label: String)] = []) throws -> Node {
  let node = Node(name: name, kind: kind, description: description)
  let source = Source(id: UUID(), nodeID: node.id, kind: SourceKind.claudeCode, path: "/p/\(name)",
                      canonicalPath: "/p/\(name)", branchKey: nil)
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}", fingerprint: name)
  try db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { source }.execute(db)
    try Event.insert { event }.execute(db)
    for e in ends {
      try LooseEnd.insert {
        LooseEnd(nodeID: node.id, sourceEventID: event.id, text: e.text, quote: e.quote,
                 role: "user", label: e.label)
      }.execute(db)
    }
  }
  return node
}

private func allVisible(_ db: any DatabaseReader) throws -> Set<UUID> {
  Set(try ProjectQueries.all(db).map(\.id))
}

@Test func searchShortCircuitsBelowMinLength() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-min"))
  _ = try seed(db, name: "Auth")
  #expect(try SearchQueries.search(query: "a", visibleNodeIDs: allVisible(db), db).isEmpty)
  #expect(try SearchQueries.search(query: "  ", visibleNodeIDs: allVisible(db), db).isEmpty)
  #expect(try SearchQueries.search(query: "🚀", visibleNodeIDs: allVisible(db), db).isEmpty) // 1 grapheme
}

@Test func searchMatchesNodeNameAndDescription() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-node"))
  _ = try seed(db, name: "Authentication")
  _ = try seed(db, name: "Sync daemon", description: "handles authentication tokens")
  let r = try SearchQueries.search(query: "authentication", visibleNodeIDs: allVisible(db), db)
  #expect(r.nodes.count == 2)
  // name-match ("Authentication") ranks before description-only ("Sync daemon")
  #expect(r.nodes.first?.name == "Authentication")
}

@Test func searchMatchesLooseEndTextAndQuote() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-le"))
  _ = try seed(db, name: "P", ends: [
    (text: "finish the deploy pipeline", quote: "irrelevant", label: ""),
    (text: "unrelated", quote: "remember the deploy vars", label: ""),
  ])
  let r = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(db), db)
  #expect(r.looseEnds.count == 2)
  // text-match ranks before quote-only match
  #expect(r.looseEnds.first?.snippet.match == "deploy")
  #expect(r.looseEnds.first?.nodeName == "P")
}

@Test func searchExcludesResolvedAndNoiseLooseEnds() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-noise"))
  _ = try seed(db, name: "P", ends: [
    (text: "open deploy item", quote: "q", label: ""),
    (text: "noisy deploy item", quote: "q", label: LooseEndLabel.noise),
  ])
  let r = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(db), db)
  #expect(r.looseEnds.count == 1)
  #expect(r.looseEnds.first?.snippet.match == "deploy")
}

@Test func searchExcludesNodesOutsideVisibleSet() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-focus"))
  let a = try seed(db, name: "Deploy A")
  _ = try seed(db, name: "Deploy B", ends: [(text: "deploy end", quote: "q", label: "")])
  let visible: Set<UUID> = [a.id]   // only A visible
  let r = try SearchQueries.search(query: "deploy", visibleNodeIDs: visible, db)
  #expect(r.nodes.map(\.id) == [a.id])
  #expect(r.looseEnds.isEmpty)      // B's loose end excluded with B
}

@Test func searchIsDeterministicOnTiedKeys() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-tie"))
  // Two nodes with identical names → tiebreak on id.uuidString, stable across runs.
  _ = try seed(db, name: "Dup deploy")
  _ = try seed(db, name: "Dup deploy")
  let r1 = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(db), db)
  let r2 = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(db), db)
  #expect(r1.nodes.map(\.id) == r2.nodes.map(\.id))
  #expect(r1.nodes.map(\.id) == r1.nodes.map(\.id).sorted { $0.uuidString < $1.uuidString })
}

@Test func searchCapsAtFiftyButReportsPreCapTotal() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-cap"))
  for i in 0..<60 { _ = try seed(db, name: "deploy \(i)") }
  let r = try SearchQueries.search(query: "deploy", visibleNodeIDs: allVisible(db), db)
  #expect(r.nodes.count == 50)
  #expect(r.totalNodeMatches == 60)
}

@Test func searchEmptyDBReturnsEmpty() throws {
  let db = try openCanonicalDatabase(at: tempURL("search-empty"))
  #expect(try SearchQueries.search(query: "deploy", visibleNodeIDs: [], db).isEmpty)
}
```

> Note: confirm `Source`'s memberwise init parameters against `Sources/PensieveKit/Model/Source.swift` before running — adjust the `seed` helper's `Source(...)` call if the labels differ. The loose-end/node columns used here (`name`, `description`, `text`, `quote`, `label`) are verified against the models.

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter SearchQueries`
Expected: FAIL — `cannot find 'SearchQueries' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/PensieveKit/Query/SearchQueries.swift
import Foundation
import SQLiteData

public struct NodeHit: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var kind: String
  public var snippet: Snippet
}

public struct LooseEndHit: Identifiable, Equatable, Sendable {
  public let id: UUID          // loose-end id (the row to auto-expand)
  public var nodeID: UUID
  public var nodeName: String
  public var snippet: Snippet
}

public struct SearchResults: Equatable, Sendable {
  public var nodes: [NodeHit]
  public var looseEnds: [LooseEndHit]
  public var totalNodeMatches: Int
  public var totalLooseEndMatches: Int
  public init(nodes: [NodeHit] = [], looseEnds: [LooseEndHit] = [],
              totalNodeMatches: Int = 0, totalLooseEndMatches: Int = 0) {
    self.nodes = nodes; self.looseEnds = looseEnds
    self.totalNodeMatches = totalNodeMatches; self.totalLooseEndMatches = totalLooseEndMatches
  }
  public var isEmpty: Bool { nodes.isEmpty && looseEnds.isEmpty }
}

/// Read-only find over the grounded core corpus (node name/description, open loose-end text/quote),
/// scoped to `visibleNodeIDs` (the caller passes the Focus-visible set → Focus filtering is correct
/// by construction). Case-insensitive substring match in Swift (correct for non-ASCII; the corpus is
/// small and single-user). Deterministic ranking with an `id.uuidString` final tiebreaker.
public enum SearchQueries {
  public static let minQueryLength = 2
  private static let cap = 50

  public static func search(query rawQuery: String,
                            visibleNodeIDs: Set<UUID>,
                            _ db: any DatabaseReader) throws -> SearchResults {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= minQueryLength else { return SearchResults() }
    func hit(_ s: String) -> Bool { s.range(of: query, options: .caseInsensitive) != nil }

    return try db.read { db in
      let nodes = try ProjectQueries.all(db).filter { visibleNodeIDs.contains($0.id) }

      // NODES — rank 0 = name match, rank 1 = description-only match.
      var nodeScored: [(rank: Int, node: Node)] = []
      for n in nodes {
        let nameHit = hit(n.name)
        if nameHit { nodeScored.append((0, n)) }
        else if hit(n.description) { nodeScored.append((1, n)) }
      }
      let sortedNodes = nodeScored.sorted { a, b in
        if a.rank != b.rank { return a.rank < b.rank }
        if a.node.name != b.node.name { return a.node.name < b.node.name }
        return a.node.id.uuidString < b.node.id.uuidString
      }
      let nodeHits = sortedNodes.prefix(cap).map { e -> NodeHit in
        let src = e.rank == 0 ? e.node.name : e.node.description
        return NodeHit(id: e.node.id, name: e.node.name, kind: e.node.kind,
                       snippet: SnippetMaker.make(from: src, matching: query))
      }

      // LOOSE ENDS — open + not-noise, visible nodes only. rank 0 = text match, 1 = quote-only.
      let nameByID = Dictionary(nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
      let ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(db)
        .filter { visibleNodeIDs.contains($0.nodeID) }
      var leScored: [(rank: Int, le: LooseEnd)] = []
      for le in ends {
        let textHit = hit(le.text)
        if textHit { leScored.append((0, le)) }
        else if hit(le.quote) { leScored.append((1, le)) }
      }
      let sortedEnds = leScored.sorted { a, b in
        if a.rank != b.rank { return a.rank < b.rank }
        if a.le.createdAt != b.le.createdAt { return a.le.createdAt > b.le.createdAt }
        return a.le.id.uuidString < b.le.id.uuidString
      }
      let leHits = sortedEnds.prefix(cap).map { e -> LooseEndHit in
        let src = e.rank == 0 ? e.le.text : e.le.quote
        return LooseEndHit(id: e.le.id, nodeID: e.le.nodeID,
                           nodeName: nameByID[e.le.nodeID] ?? "",
                           snippet: SnippetMaker.make(from: src, matching: query))
      }

      return SearchResults(nodes: Array(nodeHits), looseEnds: Array(leHits),
                           totalNodeMatches: sortedNodes.count,
                           totalLooseEndMatches: sortedEnds.count)
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter SearchQueries`
Expected: PASS (8 tests). If a compile error hits `Source(...)` labels, fix the test helper per the note in Step 1.

- [ ] **Step 5: Run the full suite (no regressions)**

Run: `./scripts/test.sh`
Expected: PASS (prior count + 17 new = 337).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/SearchQueries.swift Tests/PensieveKitTests/SearchQueriesTests.swift
git commit -F - <<'EOF'
feat(kit): SearchQueries — grounded, Focus-scoped, deterministic find

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SPid7S4FhCUroJMMmPhFy1
EOF
```

---

### Task 3: Remove the ⌘K palette (retain `PaletteDestination`)

**Files:**
- Delete: `Sources/PensieveApp/PaletteView.swift`
- Modify: `Sources/PensieveApp/AppModel.swift` (remove `showPalette`, `matchingNodes(_:)`)
- Modify: `Sources/PensieveApp/RootView.swift` (remove the palette `.sheet`)
- Modify: `Sources/PensieveApp/PensieveApp.swift` (remove the `Quick Jump…` button)
- Modify: `Sources/PensieveApp/Localizable.xcstrings` (remove `"Quick Jump…"` and `"Jump to…"` keys)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new. **Leaves `PaletteDestination`, `.apply(to:)`, `DeepLinkNavigation`, `applyDeepLink` untouched.**

- [ ] **Step 1: Delete `PaletteView.swift`**

```bash
git rm Sources/PensieveApp/PaletteView.swift
```

- [ ] **Step 2: Remove `showPalette` and `matchingNodes` from `AppModel.swift`**

Delete the `@Published var showPalette` declaration (grep `showPalette`), and delete the whole `matchingNodes(_:)` method (`AppModel.swift:402-407`):

```swift
  /// Nodes whose name contains `query` (case-insensitive); empty query returns all. For ⌘K.
  func matchingNodes(_ query: String) -> [Node] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return allNodes }
    return allNodes.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
  }
```

- [ ] **Step 3: Remove the palette `.sheet` from `RootView.swift`**

Delete this block (`RootView.swift:47-50`):

```swift
    // ⌘K now lives in the "Go" menu (see PensieveApp.commands); the palette state lives on AppModel.
    .sheet(isPresented: $model.showPalette) {
      PaletteView(model: model, isPresented: $model.showPalette)
    }
```

- [ ] **Step 4: Remove the Quick Jump button from `PensieveApp.swift`**

In the `CommandMenu("Go")` block, delete the `Quick Jump…` button and its following `Divider()`, leaving `Refresh`:

```swift
      CommandMenu("Go") {
        Button("Refresh") { Task { await model.refreshNow() } }
          .keyboardShortcut("r", modifiers: .command)
      }
```

- [ ] **Step 5: Remove the two orphaned String Catalog keys**

Open `Sources/PensieveApp/Localizable.xcstrings` and delete the top-level entries keyed `"Quick Jump…"` and `"Jump to…"` (the palette's `TextField` prompt). Preserve JSON validity (no trailing comma issues).

- [ ] **Step 6: Build and confirm the nav core survives**

```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. Then confirm the retained core still compiles and is referenced:
```bash
rg -n "PaletteDestination|applyDeepLink" Sources/PensieveApp/DeepLinkNavigation.swift Sources/PensieveApp/MenuBarView.swift
```
Expected: matches present (unchanged).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -F - <<'EOF'
refactor(app): remove ⌘K palette; retain PaletteDestination nav core

Removes showPalette, PaletteView, matchingNodes, the Quick Jump command and
its strings. PaletteDestination/applyDeepLink/DeepLinkNavigation (deep links,
App Intents, menu-bar) are untouched — .searchable replaces the palette next.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SPid7S4FhCUroJMMmPhFy1
EOF
```

---

### Task 4: `AppModel` search state + `runSearch()` funnel + selection

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift`

**Interfaces:**
- Consumes: `SearchQueries.search` / `SearchResults` / `LooseEndHit` (Task 2); `NodeContextResolver.visibleNodeIDs`; the existing `db: (any DatabaseWriter)?`, `allNodes`, `activeFocusContext`.
- Produces (used by Tasks 5–7):
  - `@Published var searchText: String` (default `""`)
  - `@Published private(set) var searchResults: SearchResults` (default `SearchResults()`)
  - `@Published var expandedLooseEndID: UUID?` (default `nil`)
  - `func runSearch()`
  - `func selectSearchNode(_ id: UUID)`
  - `func selectSearchLooseEnd(_ hit: LooseEndHit)`
  - `func clearSearch()`

- [ ] **Step 1: Add the search state**

Add near the other `@Published` properties (e.g. by `refreshToken` around `AppModel.swift:207`):

```swift
  // MARK: - In-app find
  @Published var searchText: String = ""
  @Published private(set) var searchResults: SearchResults = SearchResults()
  /// The loose-end row a search hit should auto-expand + scroll to. Consumed by LooseEndRow/DetailView.
  @Published var expandedLooseEndID: UUID?
  private var searchTask: Task<Void, Never>?
  private var searchToken = 0
```

- [ ] **Step 2: Add `runSearch()`, the selection handlers, and `clearSearch()`**

Add these methods (e.g. after `middleTitle`/`detailShowsLooseEnds`, around `AppModel.swift:400`). `runSearch` mirrors `provenance(for:)`'s off-main `Task.detached` capturing the `DatabaseWriter`:

```swift
  /// The one entry point for every search trigger (keystroke change AND the liveness refresh).
  /// Cancels the prior task; runs the read off-main; assigns results under a monotonic token so a
  /// stale keystroke can't overwrite a newer result. Below the min length → clears results.
  func runSearch() {
    searchTask?.cancel()
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= SearchQueries.minQueryLength, let db else {
      searchResults = SearchResults()
      return
    }
    let visible = NodeContextResolver.visibleNodeIDs(for: activeFocusContext, in: allNodes)
    searchToken += 1
    let token = searchToken
    searchTask = Task { [weak self] in
      let results = try? await Task.detached {
        try SearchQueries.search(query: query, visibleNodeIDs: visible, db)
      }.value
      guard let self, self.searchToken == token, !Task.isCancelled else { return }
      self.searchResults = results ?? SearchResults()
    }
  }

  /// A node search hit: drive the detail only (the briefing-card pattern), leaving sidebarSelection
  /// so clearing the field restores a coherent middle list. Clears any pending loose-end expand.
  func selectSearchNode(_ id: UUID) {
    expandedLooseEndID = nil
    selectedNodeID = id
  }

  /// A loose-end search hit: select its node and mark the row to auto-expand + scroll to.
  func selectSearchLooseEnd(_ hit: LooseEndHit) {
    selectedNodeID = hit.nodeID
    expandedLooseEndID = hit.id
  }

  /// Exit search mode (e.g. on sidebar navigation): clear the field, results, and pending expand.
  func clearSearch() {
    searchText = ""
    searchResults = SearchResults()
    expandedLooseEndID = nil
    searchTask?.cancel()
  }
```

- [ ] **Step 3: Call `runSearch()` from the liveness refresh**

At the end of `refresh()` (after the `lists`/`briefingCards`/forest block, ~`AppModel.swift:348`), add:

```swift
    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { runSearch() }
```

(`refresh()` is synchronous `@MainActor`; `runSearch()` only spawns a Task, so it does not block.)

- [ ] **Step 4: Also clear the expand in normal middle-node navigation**

In `selectMiddleNode(_:)` (`AppModel.swift:379`), add `expandedLooseEndID = nil` as the first line so a normal drill doesn't inherit a stale expand:

```swift
  func selectMiddleNode(_ id: UUID) {
    expandedLooseEndID = nil
    if case .node = sidebarSelection {
      sidebarSelection = .node(id)
    }
    selectedNodeID = id
  }
```

- [ ] **Step 5: Build**

```bash
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **` (no consumers yet — this is state + logic).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift
git commit -F - <<'EOF'
feat(app): AppModel search state + runSearch funnel + hit selection

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SPid7S4FhCUroJMMmPhFy1
EOF
```

---

### Task 5: `ContentListView` search-results rendering

**Files:**
- Modify: `Sources/PensieveApp/ContentListView.swift`

**Interfaces:**
- Consumes: `model.searchText`, `model.searchResults`, `model.selectSearchNode`, `model.selectSearchLooseEnd`, `model.node(_:)`, `Snippet`, `NodeBadge`, `AppearanceStyle.kindLabel`.
- Produces: a `SnippetText` view (used only here).

- [ ] **Step 1: Add a search branch to `body`**

Wrap the existing content so search results replace the normal list. Replace the current `body` opening (`ContentListView.swift:11-13`, the `let kind = …` + `Group { switch … }`) so it branches first:

```swift
  private var isSearching: Bool {
    !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    Group {
      if isSearching {
        searchResultsList()
          .navigationTitle(Text("Search"))
      } else {
        normalContent
      }
    }
  }

  @ViewBuilder private var normalContent: some View {
    let kind = model.middleKind()
    Group {
      switch kind {
      case .nodes(let items): nodeList(items)
      case .looseEndsOf: looseEndList()
      case .reviewSuggestions: reviewList()
      }
    }
    .navigationTitle(model.middleTitle)
    .navigationSubtitle(subtitle(for: kind))
    .task(id: MiddleLoadKey(kind: kind, token: model.refreshToken)) {
      switch kind {
      case .looseEndsOf(let id): looseEnds = model.looseEnds(forNode: id)
      case .reviewSuggestions: reviewItems = model.reviewItems()
      case .nodes: looseEnds = []; reviewItems = []
      }
    }
  }
```

(Everything from `nodeList` down stays as-is.)

- [ ] **Step 2: Add the results list + `SnippetText`**

Add this method to `ContentListView` and the `SnippetText` struct at file scope:

```swift
  @ViewBuilder private func searchResultsList() -> some View {
    let r = model.searchResults
    List {
      if !r.nodes.isEmpty {
        Section(header: Text("Projects")) {
          ForEach(r.nodes) { hit in
            Button { model.selectSearchNode(hit.id) } label: {
              HStack(spacing: 10) {
                if let n = model.node(hit.id) { NodeBadge(node: n, size: 22) }
                VStack(alignment: .leading, spacing: 2) {
                  SnippetText(snippet: hit.snippet)
                  Text(AppearanceStyle.kindLabel(hit.kind)).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
            .buttonStyle(.plain)
          }
        }
      }
      if !r.looseEnds.isEmpty {
        Section(header: Text("Loose ends")) {
          ForEach(r.looseEnds) { hit in
            Button { model.selectSearchLooseEnd(hit) } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(hit.nodeName).font(.caption).foregroundStyle(.secondary)
                SnippetText(snippet: hit.snippet)
              }
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .overlay {
      if r.isEmpty { ContentUnavailableView.search(text: model.searchText) }
    }
  }
```

```swift
/// Renders a grounded snippet with the matched run highlighted — three Text runs, zero index math.
struct SnippetText: View {
  let snippet: Snippet
  var body: some View {
    (Text(snippet.leading)
      + Text(snippet.match).bold().foregroundColor(.accentColor)
      + Text(snippet.trailing))
      .lineLimit(2)
  }
}
```

- [ ] **Step 3: Build + smoke-launch**

```bash
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5
PENSIEVE_DB=/tmp/find-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/find-smoke-cap.sqlite ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 4; kill %1
```
Expected: `** BUILD SUCCEEDED **`; the process launches and is killed with no crash log. (Interactive result verification happens in Task 8; the field isn't wired to focus yet.)

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/ContentListView.swift
git commit -F - <<'EOF'
feat(app): render grouped search results in the content column

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SPid7S4FhCUroJMMmPhFy1
EOF
```

---

### Task 6: `.searchable` field + Find (⌘F) + sidebar-clears-search

**Files:**
- Modify: `Sources/PensieveApp/RootView.swift`
- Modify: `Sources/PensieveApp/PensieveApp.swift`
- Modify: `Sources/PensieveApp/AppModel.swift` (add a focus-request signal)

**Interfaces:**
- Consumes: `model.searchText`, `model.runSearch()`, `model.clearSearch()`, `model.sidebarSelection`.
- Produces: `@Published var focusSearchRequested: Bool` on `AppModel`.

- [ ] **Step 1: Add the focus-request signal to `AppModel`**

Near the search state (Task 4):

```swift
  /// Set by the Find command; RootView observes it to move focus into the .searchable field.
  @Published var focusSearchRequested = false
```

- [ ] **Step 2: Wire `.searchable` + focus + onChange in `RootView`**

Add a focus state and attach `.searchable`/`.searchFocused` to the content column, plus the change/clear observers on the split view. In `RootView`:

```swift
  @FocusState private var isSearchFocused: Bool
```

Change the `content:` closure to:

```swift
    } content: {
      ContentListView(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: Text("Search"))
        .searchFocused($isSearchFocused)
    }
```

Add these modifiers to the `NavigationSplitView` (alongside the existing `.onChange(of: model.openNodeRequest)`):

```swift
    .onChange(of: model.searchText) { _, _ in model.runSearch() }
    .onChange(of: model.sidebarSelection) { _, _ in
      if !model.searchText.isEmpty { model.clearSearch() }
    }
    .onChange(of: model.focusSearchRequested) { _, requested in
      if requested { isSearchFocused = true; model.focusSearchRequested = false }
    }
```

> `placement: .sidebar` puts the field at the top of the window's leading area (Mail-like). If the build warns it's unavailable in this layout, drop the `placement:` argument (defaults are fine); the results branch is driven by `searchText`, not placement.

- [ ] **Step 3: Add the Find command in `PensieveApp.swift`**

In `CommandMenu("Go")`, add a Find item above Refresh:

```swift
      CommandMenu("Go") {
        Button("Find") { model.focusSearchRequested = true }
          .keyboardShortcut("f", modifiers: .command)
        Divider()
        Button("Refresh") { Task { await model.refreshNow() } }
          .keyboardShortcut("r", modifiers: .command)
      }
```

- [ ] **Step 4: Build + smoke-launch**

```bash
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5
PENSIEVE_DB=/tmp/find-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/find-smoke-cap.sqlite ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 4; kill %1
```
Expected: `** BUILD SUCCEEDED **`; no duplicate-⌘F build warning; launches clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/RootView.swift Sources/PensieveApp/PensieveApp.swift Sources/PensieveApp/AppModel.swift
git commit -F - <<'EOF'
feat(app): native .searchable field + ⌘F Find; sidebar nav clears search

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SPid7S4FhCUroJMMmPhFy1
EOF
```

---

### Task 7: Loose-end landing — auto-expand + scroll

**Files:**
- Modify: `Sources/PensieveApp/LooseEndRow.swift`
- Modify: `Sources/PensieveApp/DetailView.swift`
- Modify: `Sources/PensieveApp/RootView.swift`

**Interfaces:**
- Consumes: `model.expandedLooseEndID`, `model.detailShowsLooseEnds`.
- Produces: `LooseEndRow` gains `var expandedLooseEndID: UUID? = nil`.

- [ ] **Step 1: `LooseEndRow` reacts to the expand hint**

Add the parameter (with a default so the two `ContentListView` call sites compile untouched) and seed `expanded` on appear + on change. In `LooseEndRow` (after the `onLabel` property, `LooseEndRow.swift:17`):

```swift
  /// When this equals the row's loose end, the row starts/auto-expands (a search hit landing here).
  var expandedLooseEndID: UUID? = nil
```

Add these modifiers to the root `VStack` (next to the existing `.task(id: expanded)`, `LooseEndRow.swift:63`):

```swift
    .onAppear { if expandedLooseEndID == view.looseEnd.id { expanded = true } }
    .onChange(of: expandedLooseEndID) { _, newValue in
      if newValue == view.looseEnd.id { expanded = true }
    }
```

(`onAppear` handles a freshly-mounted row on a new node; `onChange` handles a second hit on an already-mounted row in the same node — Reviewer A's misfire case.)

- [ ] **Step 2: `DetailView` passes the hint, scrolls, and forces the section**

In `DetailView`, pass `expandedLooseEndID` into the row and tag rows with `.id`, and wrap the `ScrollView` in a `ScrollViewReader` that scrolls on change. Change the Loose Ends `ForEach` (`DetailView.swift:65-67`) to:

```swift
              ForEach(looseEnds, id: \.looseEnd.id) { view in
                LooseEndRow(view: view, loadProvenance: model.provenance,
                            onLabel: model.setLooseEndLabel,
                            expandedLooseEndID: model.expandedLooseEndID)
                  .id(view.looseEnd.id)
              }
```

Wrap the `ScrollView { … }` (`DetailView.swift:25`) in a `ScrollViewReader`:

```swift
    ScrollViewReader { proxy in
      ScrollView {
        …existing content…
      }
      .onChange(of: model.expandedLooseEndID) { _, id in
        guard let id else { return }
        withAnimation { proxy.scrollTo(id, anchor: .center) }
      }
    }
```

(Keep the existing `.toolbar` and `.task(id:)` on the `ScrollView`.)

- [ ] **Step 3: Force the Loose Ends section on a loose-end hit in `RootView`**

Change the `DetailView` construction in `detailColumn` (`RootView.swift:14`) so an active expand hint overrides the one-home rule:

```swift
      DetailView(model: model, node: node,
                 showsLooseEnds: model.detailShowsLooseEnds || model.expandedLooseEndID != nil)
```

- [ ] **Step 4: Build + smoke-launch**

```bash
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5
PENSIEVE_DB=/tmp/find-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/find-smoke-cap.sqlite ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
sleep 4; kill %1
```
Expected: `** BUILD SUCCEEDED **`; launches clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/LooseEndRow.swift Sources/PensieveApp/DetailView.swift Sources/PensieveApp/RootView.swift
git commit -F - <<'EOF'
feat(app): loose-end search hit auto-expands + scrolls into view

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SPid7S4FhCUroJMMmPhFy1
EOF
```

---

### Task 8: German localization + full verification

**Files:**
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:** none.

- [ ] **Step 1: Add/confirm the new chrome keys in the String Catalog**

Author these keys by hand (Xcode doesn't extract on a command-line build). English base + German `de`. If a key already exists (e.g. a bare `"Loose ends"`), reuse it — do not duplicate.

| Key (English) | German (`de`) |
|---|---|
| `Search` | `Suchen` |
| `Find` | `Suchen` |
| `Projects` | `Projekte` |
| `Loose ends` | `Lose Enden` |

(`ContentUnavailableView.search(text:)` is OS-localized — no key needed. Node names, loose-end text, and quotes are content — never add keys for them.)

- [ ] **Step 2: Build and confirm the German compiles into the bundle**

```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -Ei "Suchen|Projekte|Lose Enden"
```
Expected: `** BUILD SUCCEEDED **`; the German values print.

- [ ] **Step 3: Full manual verification pass**

Launch normally against a THROWAWAY store seeded with a few nodes + loose ends (or the real store via a plain `open` if you accept reading live data read-only — do NOT set the env vars toward live if scripting). Confirm, per the spec's verification list:

1. **⌘F** focuses the search field (no double-bound Find warning; only one Find in the Go menu).
2. Type a phrase from a known **loose end** → it appears under **Loose ends**; selecting it opens the node with that row **expanded and scrolled into view**.
3. Repeat for a **second** loose-end hit in the **same** node → the new row expands (not just the first).
4. A hit on a **childless-leaf** node's loose end still shows the Loose Ends section (one-home override).
5. A **node-name** phrase appears under **Projects** with its kind badge; selecting it shows its recall.
6. **No matches** → the native "No Results" empty state.
7. Set a **Focus** (Work/Personal) → a muted-context node/loose-end does **not** appear.
8. **Clear** the field → the normal list returns; selecting a **sidebar** row exits search.
9. **Regression:** a `pensieve://node/<id>` deep link (or a menu-bar jump / Siri "Open Node") still navigates — the retained `PaletteDestination` path works.
10. **German:** relaunch with `-AppleLanguages '(de)'` → "Suchen"/"Projekte"/"Lose Enden" render; node names / loose-end text stay English (content).

- [ ] **Step 4: Full Kit test suite (no regressions)**

```bash
./scripts/test.sh
```
Expected: PASS (337).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(app): German localization for in-app find chrome

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SPid7S4FhCUroJMMmPhFy1
EOF
```

---

## Self-Review

**Spec coverage:**
- `.searchable` surface + ⌘F focus → Task 6. ✅
- ⌘K palette removal, `PaletteDestination` retained → Task 3. ✅
- Corpus (name/description/text/quote), `isOpen`, Focus-visible set → Task 2. ✅
- `SnippetMaker` triple → Task 1. ✅
- Deterministic ranking + cap-after-sort + pre-cap totals → Task 2 (+ test). ✅
- Grouped results in content column, per-row tap, native empty state, kind badge → Task 5. ✅
- Loose-end landing (`.onChange`+`.onAppear`, ScrollViewReader, one-home override) → Task 7. ✅
- `runSearch()` funnel (keystroke + liveness, shared token, off-main `db.read`) → Task 4. ✅
- Sidebar nav clears search; expand cleared on normal nav → Tasks 4 & 6. ✅
- Orphan cleanup (`matchingNodes`, Quick-Jump strings) → Task 3. ✅
- German chrome; content never localized → Task 8. ✅
- Kit-tested, app thin + build/smoke verified → all tasks. ✅

**Two deliberate deviations from the spec, flagged in Global Constraints:** (1) node hit sets `selectedNodeID` only (briefing-card pattern) rather than mutating `sidebarSelection` — avoids the `.onChange(of: sidebarSelection)` clear-search race; (2) Find is ⌘F only, ⌘K dropped. Both to be surfaced to the user at execution handoff.

**Placeholder scan:** none — every code step carries complete code; every command carries expected output.

**Type consistency:** `Snippet(leading/match/trailing)`, `SearchResults`/`NodeHit`/`LooseEndHit`, `SearchQueries.search(query:visibleNodeIDs:_:)`, `runSearch`/`selectSearchNode`/`selectSearchLooseEnd`/`clearSearch`, `expandedLooseEndID`, `focusSearchRequested` are used identically across tasks. `SnippetText` is defined once (Task 5). ✅
