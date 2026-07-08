# Share a Node's Recall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Share action turns a node's recall into an English Markdown snapshot and hands it to the macOS share sheet (and copy/paste), from the detail toolbar and the node context menu.

**Architecture:** One tested pure PensieveKit builder (`RecallMarkdown.render`) turns a node + its narration/loose-ends/events into a Markdown string — summaries only, never the verbatim provenance quotes. Two thin app entry points feed it: the detail toolbar `ShareLink` builds from `DetailView`'s already-loaded `@State` (no DB in `body`), and a "Share Recall…" context-menu `ShareLink` builds lazily via `AppModel.recallMarkdown(for:)` (which reuses the existing `detail(for:)` gather).

**Tech Stack:** Swift 6, SwiftUI (macOS app target via XcodeGen + Xcode), `ShareLink` (macOS 13+; deployment target 15), PensieveKit (SwiftPM), Swift Testing, SQLiteData/GRDB. Spec: `docs/superpowers/specs/2026-07-08-share-node-recall-design.md`.

## Global Constraints

- **PensieveKit is the only unit-tested layer.** The app target (`Sources/PensieveApp/`) has **no unit tests** — verify app tasks with an `xcodebuild` build + non-blocking smoke-launch (recipe below) + human eyeball. Keep derivation in tested PensieveKit; keep views thin. (`CLAUDE.md`)
- **Export is English-only** — the shared Markdown has fixed English headers and capitalized raw kind/state; it is NOT localized. Node names, summaries, and captured content stay verbatim. The only localized string is the **`"Share Recall…"` context-menu label** (chrome).
- **No verbatim provenance quotes in the export.** The builder emits loose-end `.text` (summaries) only; a loose end's `.quote` must never appear. A unit test asserts this.
- **Trust gate untouched** — the builder never fabricates; it is pure (no DB, no LLM). No schema/capture/ingest/entitlement changes.
- **App build + smoke recipe** (run from repo root):
  ```bash
  xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug \
    -derivedDataPath ./.build-xcode build 2>&1 | tail -8
  ```
  Then smoke-launch the **inner binary** in the background with throwaway stores, wait ~3s, confirm no crash, kill it (never the live store; the shell is `fish`, so prefix env with `env`):
  ```bash
  env PENSIEVE_DB=/tmp/pv-share.sqlite PENSIEVE_CAPTURE_DB=/tmp/pv-share-cap.sqlite \
    ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve
  ```
  Discard any transient `Package.resolved` churn (`git checkout -- Package.resolved`) before staging.
- **Kit tests:** `./scripts/test.sh --filter <name>`.
- **SQLiteData predicates use `.eq(x)`, never `== x`.** No shared mutable `static` `DateFormatter`/`ISO8601DateFormatter` — a **local** instance per call is fine (Swift 6). Swift only.
- **Commit trailers** on every commit (use a heredoc `git commit -F -`; backticks in `-m` get shell-executed):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
  ```

---

## File Structure

- **Create** `Sources/PensieveKit/Query/RecallMarkdown.swift` — the pure Markdown builder.
- **Create** `Tests/PensieveKitTests/RecallMarkdownTests.swift` — its unit tests.
- **Modify** `Sources/PensieveApp/AppModel.swift` — add `recallMarkdown(for:)`.
- **Modify** `Sources/PensieveApp/DetailView.swift` — add a `shareMarkdown` `@State`, compute it in the existing `.task`, add a toolbar `ShareLink`.
- **Modify** `Sources/PensieveApp/NodeOrganizing.swift` — add a "Share Recall…" `ShareLink` to `NodeContextMenu`.
- **Modify** `Sources/PensieveApp/Localizable.xcstrings` — add the `"Share Recall…"` chrome key (en + de).

---

## Task 1: `RecallMarkdown.render` Kit builder

**Files:**
- Create: `Sources/PensieveKit/Query/RecallMarkdown.swift`
- Test: `Tests/PensieveKitTests/RecallMarkdownTests.swift`

**Interfaces:**
- Consumes: `Node` (`.name/.kind/.state/.description`), `LooseEndView` (`.looseEnd.text`, `.looseEnd.quote`), `Event` (`.occurredAt/.summary`).
- Produces: `public static func render(node: Node, narration: String?, looseEnds: [LooseEndView], events: [Event], now: Date) -> String`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/RecallMarkdownTests.swift`:

```swift
import Foundation
import Testing
@testable import PensieveKit

private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
  // Hour 12 in the current calendar → no midnight rollover in any real timezone, so the
  // yyyy-MM-dd the builder formats (in TimeZone.current) is deterministic across machines.
  Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

private func looseEnd(_ text: String, quote: String, on d: Date) -> LooseEndView {
  LooseEndView(looseEnd: LooseEnd(nodeID: UUID(), sourceEventID: UUID(), text: text, quote: quote),
               occurredAt: d, ageDays: 0)
}

private func event(_ summary: String, on d: Date) -> Event {
  Event(nodeID: UUID(), sourceID: UUID(), occurredAt: d, kind: "git.commit",
        summary: summary, detailJSON: "{}")
}

@Test func rendersFullRecallAsExpectedMarkdown() {
  var node = Node(name: "Auth", kind: "strand", description: "OAuth + token refresh.")
  node.state = "active"
  let md = RecallMarkdown.render(
    node: node,
    narration: "Wired up refresh-token rotation.",
    looseEnds: [looseEnd("rotate on 401", quote: "SECRET-QUOTE", on: date(2026, 7, 6))],
    events: [event("add rate limit", on: date(2026, 7, 7))],
    now: date(2026, 7, 8))

  #expect(md == """
  # Auth

  *Strand · Active*

  OAuth + token refresh.

  ## Last Work Done

  Wired up refresh-token rotation.

  ## Loose Ends

  - rotate on 401

  ## Recent Activity

  - 2026-07-07 — add rate limit

  ---
  _Shared from Pensieve · 2026-07-08_

  """)
}

@Test func neverEmitsVerbatimQuote() {
  let node = Node(name: "X", kind: "project")
  let md = RecallMarkdown.render(
    node: node, narration: nil,
    looseEnds: [looseEnd("do the thing", quote: "DISTINCTIVE-SENTINEL-QUOTE", on: date(2026, 7, 1))],
    events: [], now: date(2026, 7, 2))
  #expect(!md.contains("DISTINCTIVE-SENTINEL-QUOTE"))   // provenance quotes never leave via a share
  #expect(md.contains("- do the thing"))                // but the summary text does
}

@Test func omitsNarrationSectionWhenNil() {
  let node = Node(name: "X", kind: "project")
  let md = RecallMarkdown.render(node: node, narration: nil, looseEnds: [], events: [], now: date(2026, 7, 2))
  #expect(!md.contains("## Last Work Done"))
}

@Test func omitsNarrationSectionWhenEmptyString() {
  let node = Node(name: "X", kind: "project")
  let md = RecallMarkdown.render(node: node, narration: "", looseEnds: [], events: [], now: date(2026, 7, 2))
  #expect(!md.contains("## Last Work Done"))
}

@Test func emptyLooseEndsAndEventsShowPlaceholders() {
  let node = Node(name: "X", kind: "project")
  let md = RecallMarkdown.render(node: node, narration: nil, looseEnds: [], events: [], now: date(2026, 7, 2))
  #expect(md.contains("## Loose Ends\n\n_None open._"))
  #expect(md.contains("## Recent Activity\n\n_No captured activity._"))
}

@Test func omitsDescriptionLineWhenEmpty() {
  let node = Node(name: "X", kind: "project")   // description defaults to ""
  let md = RecallMarkdown.render(node: node, narration: nil, looseEnds: [], events: [], now: date(2026, 7, 2))
  // header line is immediately followed by the meta line and then the first section — no stray blank block
  #expect(md.contains("# X\n\n*Project · Active*\n\n## Loose Ends"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter RecallMarkdown`
Expected: FAIL — compile error, `cannot find 'RecallMarkdown' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PensieveKit/Query/RecallMarkdown.swift`:

```swift
import Foundation

/// Renders a node's recall as an English Markdown snapshot for sharing. Pure and deterministic:
/// no DB, no LLM, no localization. `narration` nil/empty ⇒ the Last Work Done section is omitted.
/// Emits loose-end SUMMARY text only — a loose end's verbatim `quote` is never included.
public enum RecallMarkdown {
  public static func render(node: Node, narration: String?, looseEnds: [LooseEndView],
                            events: [Event], now: Date) -> String {
    var out: [String] = []
    out.append("# \(node.name)")
    out.append("")
    out.append("*\(capitalizedFirst(node.kind)) · \(capitalizedFirst(node.state))*")

    if !node.description.isEmpty {
      out.append("")
      out.append(node.description)
    }

    if let narration, !narration.isEmpty {
      out.append("")
      out.append("## Last Work Done")
      out.append("")
      out.append(narration)
    }

    out.append("")
    out.append("## Loose Ends")
    out.append("")
    if looseEnds.isEmpty {
      out.append("_None open._")
    } else {
      for le in looseEnds { out.append("- \(le.looseEnd.text)") }
    }

    out.append("")
    out.append("## Recent Activity")
    out.append("")
    if events.isEmpty {
      out.append("_No captured activity._")
    } else {
      for e in events { out.append("- \(day(e.occurredAt)) — \(e.summary)") }
    }

    out.append("")
    out.append("---")
    out.append("_Shared from Pensieve · \(day(now))_")

    return out.joined(separator: "\n") + "\n"
  }

  private static func capitalizedFirst(_ s: String) -> String {
    s.isEmpty ? s : s.prefix(1).uppercased() + s.dropFirst()
  }

  /// yyyy-MM-dd in the current timezone. A local (non-static) formatter — Swift-6-safe.
  private static func day(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter RecallMarkdown`
Expected: PASS — all 6 RecallMarkdown tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Query/RecallMarkdown.swift Tests/PensieveKitTests/RecallMarkdownTests.swift
git commit -F - <<'EOF'
feat(kit): RecallMarkdown.render — a node's recall as shareable Markdown

Pure, deterministic English Markdown builder (no DB/LLM/localization).
Summaries only — a loose end's verbatim quote is never emitted (asserted
by test). Narration section omitted when absent; empty loose ends/events
render placeholders. Backs the app's Share action.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task 2: App wiring — Share from the detail toolbar and the context menu

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift`
- Modify: `Sources/PensieveApp/DetailView.swift`
- Modify: `Sources/PensieveApp/NodeOrganizing.swift`

**Interfaces:**
- Consumes: `RecallMarkdown.render(node:narration:looseEnds:events:now:)` (Task 1); existing `AppModel.detail(for:) -> (status: ProjectStatus, looseEnds: [LooseEndView])`, `AppModel.cachedNarration(for:) -> String?`; `DetailView`'s existing `@State` `recentEvents`/`looseEnds`/`lastWorkDone` and its `.task`; `NodeContextMenu` (`NodeOrganizing.swift:120`).
- Produces: `AppModel.recallMarkdown(for node: Node) -> String`; a toolbar `ShareLink` in `DetailView`; a "Share Recall…" `ShareLink` in `NodeContextMenu`.

- [ ] **Step 1: Add `AppModel.recallMarkdown(for:)`**

In `Sources/PensieveApp/AppModel.swift`, add this method right after the existing `detail(for:)` method (around `AppModel.swift:309`):

```swift
  /// The node's recall rendered as shareable English Markdown. Reuses `detail(for:)` for the gather
  /// and includes the narration only if it's already cached (a share never blocks on an LLM call).
  func recallMarkdown(for node: Node) -> String {
    let d = detail(for: node)
    return RecallMarkdown.render(node: node, narration: cachedNarration(for: node),
                                 looseEnds: d.looseEnds, events: d.status.recentEvents, now: Date())
  }
```

- [ ] **Step 2: Add the share text + toolbar `ShareLink` to `DetailView`**

In `Sources/PensieveApp/DetailView.swift`:

Add a state property next to the other `@State`s (after `loadedNodeID`, ~line 17):

```swift
  @State private var shareMarkdown = ""   // rebuilt on load/refresh; fed to the toolbar ShareLink
```

In the `.task` closure, set it right after `looseEnds = d.looseEnds` (so it's populated the moment a node loads, narration possibly cached):

```swift
      shareMarkdown = RecallMarkdown.render(node: node, narration: model.cachedNarration(for: node),
                                            looseEnds: looseEnds, events: recentEvents, now: Date())
```

and refresh it once the async narration resolves — right after `lastWorkDone = prose` (before `isNarrating = false`):

```swift
      shareMarkdown = RecallMarkdown.render(node: node, narration: prose,
                                            looseEnds: looseEnds, events: recentEvents, now: Date())
```

Add a `.toolbar` to the `ScrollView` (place it immediately before the existing `.task(id:)` modifier):

```swift
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        ShareLink(item: shareMarkdown, subject: Text(node.name))
      }
    }
```

- [ ] **Step 3: Add "Share Recall…" to the node context menu**

In `Sources/PensieveApp/NodeOrganizing.swift`, in `NodeContextMenu.body` (line ~124), insert a share entry after the `Edit…` button and its own divider:

```swift
    Button("New Child…") { model.presentNewNode(under: node.id) }
    Button("Edit…") { model.presentEditNode(node) }
    Divider()
    ShareLink("Share Recall…", item: model.recallMarkdown(for: node))
    Divider()
    Button("Move to…") { model.movePickerNodeID = node.id }
    Button("Merge into…") { model.mergePickerNodeID = node.id }
    Divider()
    Button("Delete…", role: .destructive) { model.pendingDeleteNodeID = node.id }
      .disabled(!model.canDelete(node.id))
```

(The `ShareLink` item is evaluated when the context menu is presented, not per row-render, so this does not add a per-render DB read.)

- [ ] **Step 4: Build**

Run the Global Constraints build recipe. Expected: clean build. (`"Share Recall…"` shows in English until Task 3 adds the German key — expected.)

- [ ] **Step 5: Smoke-launch**

Run the Global Constraints smoke recipe (background, ~3s, kill). Expected: launches, no crash.

- [ ] **Step 6: Commit**

```bash
git checkout -- Package.resolved 2>/dev/null || true
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/DetailView.swift Sources/PensieveApp/NodeOrganizing.swift
git commit -F - <<'EOF'
feat(app): Share a node's recall (detail toolbar + context menu)

Toolbar ShareLink builds the recall Markdown from DetailView's loaded
@State (no DB in body) and rides along to the ⌘⌥N recall window; a
"Share Recall…" context-menu ShareLink shares any node's recall lazily
via AppModel.recallMarkdown(for:) (reuses detail(for:), narration only if
cached). Both go through RecallMarkdown.render.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Task 3: Localize the "Share Recall…" menu label (German)

Add the one new chrome key introduced in Task 2 to the String Catalog by hand (`xcodebuild` does not auto-populate keys). The exported document stays English; only this menu label is localized.

**Files:**
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: the `"Share Recall…"` literal from `NodeContextMenu` (Task 2).
- Produces: en/de translations for `"Share Recall…"`.

- [ ] **Step 1: Confirm the key is missing**

Run:
```bash
python3 -c "import json; s=json.load(open('Sources/PensieveApp/Localizable.xcstrings'))['strings']; print('Share Recall…', 'PRESENT' if 'Share Recall…' in s else 'MISSING')"
```
Expected: `MISSING`.

- [ ] **Step 2: Add the key (en + de)**

Run (adds only if missing, then re-sorts):
```bash
python3 - <<'PY'
import json
p="Sources/PensieveApp/Localizable.xcstrings"
d=json.load(open(p)); s=d["strings"]
key="Share Recall…"
if key not in s:
    s[key]={"localizations":{
        "en":{"stringUnit":{"state":"translated","value":"Share Recall…"}},
        "de":{"stringUnit":{"state":"translated","value":"Rückblick teilen…"}}}}
d["strings"]=dict(sorted(s.items()))
json.dump(d, open(p,"w"), ensure_ascii=False, indent=2); open(p,"a").write("\n")
print("added")
PY
```
(Xcode re-normalizes the JSON whitespace on next open — expected, harmless.)

- [ ] **Step 3: Build and verify the German compiled into the bundle**

Run the Global Constraints build recipe, then:
```bash
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings \
  | grep -i "Rückblick teilen"
```
Expected: build succeeds; the German value appears.

- [ ] **Step 4: Commit**

```bash
git checkout -- Package.resolved 2>/dev/null || true
git add Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
chore(l10n): German for the "Share Recall…" menu label

Adds Share Recall… → "Rückblick teilen…" (chrome). The exported recall
Markdown itself stays English by design.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ya7ToQ9MrGVDLzHkDB1mg3
EOF
```

---

## Human-verify carries (need the built app + real store + plain `open`)

Build: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`, then `open ./.build-xcode/Build/Products/Debug/Pensieve.app`.

1. Select a node → the **detail toolbar Share button** opens the macOS share sheet; sharing to Notes/Mail (or Copy) yields the recall as Markdown text (title, `*Kind · State*`, Last Work Done if present, Loose Ends, Recent Activity, footer).
2. The **⌘⌥N recall window** also shows the Share button and shares that node's recall.
3. **Right-click a sidebar/middle row → "Share Recall…"** shares that node's recall without opening it.
4. A node with **no open loose ends / no activity** shares with `_None open._` / `_No captured activity._`.
5. The shared text contains **no verbatim provenance quote** — only loose-end summary text.
6. **German:** with `-AppleLanguages '(de)'`, the context-menu item reads **"Rückblick teilen…"**; the exported document stays English.

## Self-Review (completed while writing)

- **Spec coverage:** ShareLink/Markdown-text delivery → Task 2; summaries-only + no-quotes → Task 1 (builder + invariant test); English export → Task 1 (fixed headers, capitalized kind/state, yyyy-MM-dd); toolbar + context-menu surface → Task 2; narration cached-only → Tasks 1 (nil-omit) + 2 (`cachedNarration`); recall-window free → Task 2 (ShareLink on DetailView); localized menu label only → Task 3; trust gate/no-entitlement → builder is pure, ShareLink in-process. No gaps.
- **Type consistency:** `RecallMarkdown.render(node:narration:looseEnds:events:now:)` identical across Tasks 1–2; `LooseEndView.looseEnd.text/.quote`, `Event.occurredAt/.summary`, `Node.name/.kind/.state/.description`, `AppModel.detail(for:)`/`cachedNarration(for:)` match the codebase (verified against sources).
- **Placeholder scan:** none.
