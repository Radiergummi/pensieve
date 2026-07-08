# Share a node's recall — design

**Date:** 2026-07-08
**Status:** Approved (brainstorm complete; ready for a plan)
**Scope:** `Sources/PensieveApp/` (app target) + one tested PensieveKit builder. No trust-gate, capture, ingest, schema, or entitlement changes.
**Backlog item:** "Sharing — export & share a node's grounded recall (its own spec)."

## Problem / intent

Get a node's recall — the grounded summary the app already shows (What It Is, the Last-Work-Done recap, loose
ends, recent activity) — **out of Pensieve** as a portable artifact: paste into a status update, send to a
colleague, keep a snapshot. Single-user export; no recipients infrastructure, no CloudKit (a share is a
read-only snapshot, not a live link).

## Decisions (from brainstorming)

1. **Delivery:** a SwiftUI `ShareLink` hands the recall to the macOS share sheet as a **Markdown text string**
   (`String` is `Transferable` → shares as text; routes to Messages/Mail/Notes/paste; copy/paste is free). No
   entitlements — in-process, no App Group (unlike Widgets, which are deferred).
2. **Content — summaries only, NO verbatim provenance quotes.** Raw captured text (transcript/commit snippets)
   never leaves the device. A loose end's *summary text* already passed the in-app grounding gate, so exporting
   it without its quote is a grounded summary, not a fabrication — the quote is just the receipt, and it stays
   in-app.
3. **Export is English-only.** The shared Markdown is a neutral document format with fixed English headers and
   capitalized raw kind/state; it is NOT localized. (The *menu label* that triggers a share IS chrome and is
   localized — see below.)
4. **Surface:** a `ShareLink` in the detail column's trailing toolbar + a "Share Recall…" item in the node
   context menu on sidebar/middle rows.
5. **Trust gate untouched:** the builder never fabricates; omitting quotes is a content choice, not a gate
   change.

## The Markdown format (fixed, English, deterministic)

```
# <node.name>

*<Kind> · <State>*

<node.description>            ← omitted if empty

## Last Work Done             ← whole section omitted if no narration available

<narration>

## Loose Ends

- <loose end summary text>
- <loose end summary text>
                              ← or, if none open:  _None open._

## Recent Activity

- <yyyy-MM-dd> — <event summary>
- <yyyy-MM-dd> — <event summary>
                              ← or, if none:  _No captured activity._

---
_Shared from Pensieve · <yyyy-MM-dd>_
```

- **Kind/State** render by capitalizing the raw `node.kind` / `node.state` string (e.g. `strand` → `Strand`,
  `active` → `Active`) — no dependency on the app's localized `AppearanceStyle` labels.
- **Dates** use a fixed `yyyy-MM-dd` format (locale-independent → deterministic for tests).
- **Loose Ends** lists each open loose end's `.looseEnd.text` only. The `.looseEnd.quote` is **never** emitted
  (a unit test asserts this).
- **Recent Activity** lists the same recent events the recall shows (most-recent first), each as
  `date — summary`. No source glyphs (plain text export).

## Architecture

### PensieveKit (tested, pure) — `Sources/PensieveKit/Query/RecallMarkdown.swift`

```swift
public enum RecallMarkdown {
  /// Render a node's recall as an English Markdown snapshot. Pure and deterministic: no DB, no LLM,
  /// no localization. `narration` nil ⇒ the Last Work Done section is omitted. Never emits a loose
  /// end's verbatim `quote` — summaries only.
  public static func render(node: Node, narration: String?, looseEnds: [LooseEndView],
                            events: [Event], now: Date) -> String
}
```

Deterministic given its inputs, so it is fully unit-testable without a store or provider. It is the single
place the share content is built; both app entry points call it.

### App (thin) — two entry points to the one builder

- **`AppModel.recallMarkdown(for node: Node) -> String`** — gathers the node's recent events + open loose ends
  via the existing queries (`ProjectQueries.status` / `LooseEndQueries.open`), passes the node's **cached**
  narration if present (else nil), and returns `RecallMarkdown.render(...)`. Used by the context-menu entry
  (the node may not be open, so there's no in-memory `@State` to read). One-shot DB read, invoked lazily when
  the context menu is opened.
- **Detail toolbar `ShareLink`** — contributed by `DetailView` via its own `.toolbar` (placement
  `.primaryAction`, joining Refresh/Inspector). It builds the Markdown from `DetailView`'s **already-loaded
  `@State`** (`recentEvents`, `looseEnds`, `lastWorkDone`) by calling `RecallMarkdown.render(...)` directly —
  pure string work, **no DB query in `body`**. Because it lives in `DetailView`, the ⌘⌥N recall window gets the
  Share button too, for free.
- **`NodeContextMenu` "Share Recall…"** — a `ShareLink("Share Recall…", item: model.recallMarkdown(for: node))`.
  Context-menu content is evaluated lazily on menu presentation, so this does not run per row-render.

`ShareLink(item: markdown, subject: Text(node.name))` shares the Markdown as text; the subject seeds a Mail
subject line. The default system ShareLink label (share glyph) is used on the toolbar; the context-menu variant
carries the explicit "Share Recall…" label.

### Localization

The **export is English** (no catalog keys). The one new **chrome** string is the context-menu label
`"Share Recall…"`, added to `Localizable.xcstrings` (en base + `de`) by hand. The toolbar `ShareLink` uses the
system-provided (already-localized) share affordance, no custom string. Node names, summaries, and captured
content are never localized (content).

## Edge cases

- **No narration cached** (context-menu share of a never-opened node, or provider failure) → the Last Work Done
  section is omitted. Best-effort, consistent with how narration works in-app.
- **No open loose ends** → `_None open._`. **No events** → `_No captured activity._`.
- **Empty description** → the description line is omitted (no blank).
- **A node with children (parent)** shares its own recall (its own loose ends/events), same as the detail shows
  — children are not recursively included (a recall is one node's snapshot).

## Testing & verification

- **PensieveKit unit tests** for `RecallMarkdown.render`:
  - full node (name/kind/state/description + narration + 2 loose ends + 2 events) → exact expected Markdown
    (fixed date format makes this deterministic);
  - narration nil → no "Last Work Done" heading;
  - empty loose ends → `_None open._`; empty events → `_No captured activity._`; empty description → no blank
    line;
  - **no-quotes invariant:** given a loose end whose `quote` is a distinctive sentinel string, assert the output
    does **not** contain it;
  - kind/state capitalization (`strand` → `Strand`).
- **App target (no unit tests, per convention):** `xcodebuild` build + non-blocking smoke-launch. Human-eyeball
  carries (need the built app + real store + `open`):
  - the detail toolbar Share button opens the macOS share sheet with the recall as text; pasting into Notes/Mail
    shows the Markdown; the ⌘⌥N recall window also shows Share;
  - the context-menu "Share Recall…" on a sidebar/middle row shares that node's recall without opening it;
  - a share of a node with no open loose ends / no activity reads correctly (the empty lines);
  - the exported text contains **no** verbatim provenance quote;
  - German: the "Share Recall…" menu label renders in German in situ (`-AppleLanguages '(de)'`); the exported
    document stays English.

Build: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug
-derivedDataPath ./.build-xcode build`, then `open ./.build-xcode/Build/Products/Debug/Pensieve.app`.

## Out of scope / deferred

- File export (Save panel → `.md`/PDF) and a "Share with provenance (quotes)" variant — both were considered and
  deferred to keep the first cut minimal; either can be added later atop the same builder.
- A shareable **link** / collaborative sharing — needs the CloudKit pillar (itself gated on a paid team; see the
  App-Groups deferral in `backlog.md`).
- Recursive/rolled-up recall for a parent's whole subtree.
