# Three-pane slice 3a: LLM "Last Work Done" narration — design

**Date:** 2026-07-06
**Status:** approved (brainstorm complete), pre-plan
**Parent design:** `specs/2026-07-05-pensieve-app-three-pane-design.md` (slice 3). This carves the
highest-value piece of slice 3 — the LLM "Last Work Done" narration — into its own focused slice
(**3a**). The rest of slice 3 (`ValueObservation` liveness, ⌘⌥I inspector, window/materials polish)
becomes later follow-ups (3b…), each its own spec.

## Goal

Replace the detail view's deterministic **Recent Activity** stand-in's role as the *only* recap with
a real, grounded **"Last Work Done"** prose narration — the field the parent design calls "the
highest-value field." This is the **first LLM call in the app**. It wires the already-tested
Phase-1B `SummaryBuilder` narration into `DetailView`, appearing automatically when you open a node,
generated on-device, degrading honestly when it can't be produced.

The narration is **best-effort and outside the strict grounded-cite trust gate** (like strand
naming): the model narrates *only* a deterministic fact sheet (`SummaryBuilder`'s existing
constrained prompt), and loose ends stay individually cited. Recent Activity stays as both the
instant content and the ground truth the prose is derived from.

## Non-goals (deferred → the rest of slice 3 / backlog)

- **`ValueObservation` liveness** (slice 3b). This slice keeps the existing 3 s `Timer` + manual
  ⌘R refresh; it reuses ⌘R (not live observation) to re-narrate.
- **⌘⌥I provenance inspector** (slice 3b).
- **Window tabbing / materials / light-dark / toolbar polish** (slice 3b).
- **Persisting narrations** (CloudKit/DB). Cache is in-memory, session-lifetime.
- **Talk-to-system / any LLM *write* path** (slice 5). This is read-only narration.

## Decisions locked during brainstorming

1. **Scope:** narration only (slice 3a). B/C/D of slice 3 deferred.
2. **Trigger:** **automatic on open, progressive** — show Recent Activity immediately; fire narration
   async; reveal the prose section when it returns, with a subtle loading indicator meanwhile.
3. **Honest degradation:** on no-events **or** provider failure/unavailability, show **nothing
   extra** — the "Last Work Done" section appears *only* on a genuine model narration; never a
   fact-sheet dressed as prose. Backed by a new `narrate → String?` boundary that returns `nil`
   rather than falling back to facts.
4. **Provider:** reuse `makeDefaultLLMProvider()` — on-device FoundationModels when available
   (macOS 26+), else the `claude -p` `ClaudeCLIProvider`. **Realistic in-app path is on-device**: a
   bundled `.app` launched from Finder doesn't inherit the shell `PATH`, so `claude -p` may not
   resolve → narration returns `nil` → the section is simply absent (honest degradation).
5. **Freshness (judgment call #1):** ⌘R clears the cache and re-narrates the open node (reuse the
   manual refresh, not liveness).
6. **Cache (judgment call #2):** session-lifetime, `[UUID: String]`, invalidated only by ⌘R. No
   expiry, no persistence.

## Architecture

### PensieveKit (tested) — a narrower, honest narration boundary

Add one method beside the existing `SummaryBuilder.build` (which is untouched — the CLI still uses
its DB-fetching, facts-fallback variant):

```swift
extension SummaryBuilder {
  /// Best-effort prose recap of the given events. Returns nil when there is nothing to narrate
  /// (no events) OR the provider fails/is unavailable/returns empty — never substitutes the raw
  /// fact sheet, so a caller can show the section only on a genuine narration. Takes events directly
  /// (no DB re-query) so the prose narrates exactly what the caller already displays.
  public func narrate(project: Node, events: [Event]) async -> String?
}
```

Behavior:
- `events.isEmpty` → `nil`.
- Else assemble `Self.assembleFacts(project:events:)` (the existing deterministic, prefix-15 fact
  sheet) and call the injected `provider.complete(prompt:)` with the existing constrained prompt.
- Provider **throws** → `nil` (no facts substitution).
- Provider **succeeds** → **trim whitespace/newlines; if the result is empty, return `nil`**, else the
  trimmed prose. (Review finding #4: a provider can succeed with `""`; without this guard the app
  renders a "LAST WORK DONE" header with no body — the fact-sheet-dressed-as-prose failure the design
  forbids.)

**`SummaryBuilder` must be declared `Sendable`** (review finding #3). It compiles in Swift 6 language
mode, and an `@MainActor AppModel` will hold it and `await` it — sending a non-`Sendable` value out of
the main-actor region is a data-race error. The conformance is free: its only stored property is
`provider: any LLMProvider`, and `LLMProvider` is already `Sendable`. This is load-bearing for the
"runs off the main actor without blocking" claim to actually compile.

**Extract the shared prompt** (review finding #6): the constrained prompt is currently inline in
`build`. Lift it to a `private static func makePrompt(facts:) -> String` used by **both** `build` and
`narrate`, so the wording can't drift between the two.

This keeps the trust-sensitive derivation in tested PensieveKit; the app view stays thin.

### App target (thin)

**`AppModel`** (`@MainActor`) — owns the provider + cache and exposes one async accessor:
- `private lazy var summaryBuilder = SummaryBuilder(provider: makeDefaultLLMProvider())` — one
  provider for the app's lifetime (created lazily on first narration, so launch never probes the LLM).
- `private var narrationCache: [UUID: String] = [:]`.
- `private(set) var refreshToken = 0` (`@Published`) — bumped by the refresh path.
- `func narration(for node: Node, events: [Event]) async -> String?` — returns `narrationCache[node.id]`
  if present; else `await summaryBuilder.narrate(project: node, events: events)`, stores **non-`nil`**
  results, returns it. The `await` runs the provider **off the main actor** (`SummaryBuilder` is
  `Sendable` and its `narrate`/the providers are nonisolated `async`), so the UI never blocks. *Note
  (#7): failures aren't cached — a no-provider machine re-attempts on each open; intentional so
  narration can appear if a provider later becomes available, and cheap on-device. The `claude -p`
  fallback (#5) parks a cooperative-pool thread for the subprocess's lifetime; acceptable single-user
  and fallback-only, but the plan should wrap that provider's blocking call in `Task.detached` if it
  proves to matter.*
- `func cachedNarration(for node: Node) -> String?` — a **synchronous** cache peek, so a re-opened
  cached node renders the prose immediately without a spinner flicker (#8b).
- In `drainThenRefresh()` (launch + ⌘R): **immediately after `refresh()` and *before* the existing
  `await SpotlightIndexer.reindex()`** (#8a — so ⌘R re-narration isn't delayed by the reindex),
  `narrationCache.removeAll()` and `refreshToken += 1`. (The 3 s `Timer` calls `refresh()` directly,
  *not* `drainThenRefresh()`, so narration is never invalidated on every tick — same boundary the
  Spotlight reindex uses; verified against `AppModel`.)

**`DetailView`** — a "Last Work Done" section above Recent Activity:
- New `@State private var lastWorkDone: String?` and `@State private var isNarrating = false`.
- Change the load to `.task(id: DetailLoadKey(nodeID: node.id, token: model.refreshToken))` (a tiny
  `Hashable` struct) so the open node reloads its events **and** re-narrates after ⌘R — fixing a
  latent gap (today the open detail view doesn't refresh on ⌘R). `DetailView` is reused across
  selections (SwiftUI swaps `node`, keeping one instance and its `@State`), so the task body MUST
  handle the handoff carefully:

  ```
  .task(id: DetailLoadKey(node.id, model.refreshToken)) {
    // Reset FIRST so node B never shows node A's prose while B narrates (#1).
    lastWorkDone = nil
    let d = model.detail(for: node)
    recentEvents = d.status.recentEvents
    looseEnds = d.looseEnds
    // Instant on a cache hit — no spinner flicker (#8b).
    if let cached = model.cachedNarration(for: node) { lastWorkDone = cached; return }
    isNarrating = true
    let prose = await model.narration(for: node, events: recentEvents)
    // Guard against a superseded task's late result poisoning the current node (#2): when the
    // selection changed, SwiftUI cancelled this task, but the await still resumed.
    guard !Task.isCancelled else { return }
    lastWorkDone = prose
    isNarrating = false
  }
  ```
- Render: a `LAST WORK DONE` section that shows a small inline `ProgressView` while `isNarrating`,
  the prose once `lastWorkDone != nil`, and **is omitted entirely** when narration finished `nil`
  (honest degradation). Recent Activity stays exactly as-is below it. *(Optional, not required: a
  subtle "recap" caption on the section so the prose never reads as authoritative cited text; the
  grounded loose ends sit below it. Single-user, low stakes — a plan-time touch at most.)*

### Data flow

```
select node / ⌘R  →  DetailView.task(nodeID, refreshToken)
    →  recentEvents = model.detail(for:).status.recentEvents   (instant; Recent Activity renders)
    →  lastWorkDone = await model.narration(for: node, events: recentEvents)
           →  cache hit → instant
           →  miss → SummaryBuilder.narrate → provider.complete (off-main) → prose | nil
    →  render LAST WORK DONE only if non-nil
```

## Error handling & edge cases

- **No provider reachable** (bundled GUI, no FoundationModels, `claude` not on `PATH`): `narrate`
  returns `nil` → section absent. No error surfaced to the user; a glance surface must not nag.
- **Node with no events**: `nil` → section absent (Recent Activity shows "No captured activity").
- **Slow provider**: the async task holds `isNarrating`; the rest of the view (What It Is, Loose
  Ends, Recent Activity) is already interactive. Re-selecting a different node changes the `.task`
  id; SwiftUI cancels the prior task, but `narrate`/the providers don't check cancellation, so the
  old `await` still resumes — the **`reset-on-entry` + `Task.isCancelled` guard** (see `DetailView`
  above) is what actually prevents a stale/superseded result from rendering under the wrong node
  (#1/#2). The `narrationCache` write is keyed by `node.id`, so the cache is never poisoned.
- **Never blocks the capture path or the main actor** — narration is read-only and off-main.

## Testing

- **PensieveKit (unit) — the trust-sensitive boundary:** `SummaryBuilder.narrate` with a stub
  `LLMProvider`:
  - success provider + non-empty events → returns the provider's prose (trimmed);
  - throwing provider → `nil` (asserts **no** facts substitution);
  - **empty/whitespace-only success → `nil`** (asserts no empty-header render, #4);
  - empty events → `nil` (provider never called).
- **App target (no unit tests):** `xcodebuild` build + non-blocking smoke-launch against a throwaway
  empty store (no events → no narration → no crash). Keep derivation in PensieveKit; view stays thin.
- **Human verification** (needs a live provider, can't be asserted headlessly): open a real project
  with activity → a 2–3 sentence "Last Work Done" recap appears above Recent Activity within a
  couple seconds; ⌘R re-narrates; a no-activity node shows no such section.

## Files

**New**
- `Tests/PensieveKitTests/SummaryBuilderNarrateTests.swift` — the three `narrate` cases with a stub provider.

**Modified**
- `Sources/PensieveKit/Intelligence/SummaryBuilder.swift` — declare `SummaryBuilder: Sendable`;
  extract `makePrompt(facts:)` shared by `build` + the new `narrate(project:events:) async -> String?`
  (trim → empty maps to `nil`).
- `Sources/PensieveApp/AppModel.swift` — lazy `SummaryBuilder(provider: makeDefaultLLMProvider())` +
  `narrationCache` + `narration(for:events:)` + sync `cachedNarration(for:)`; `@Published private(set)
  refreshToken`; cache-clear + token-bump in `drainThenRefresh()` right after `refresh()`, before the
  `await SpotlightIndexer.reindex()`.
- `Sources/PensieveApp/DetailView.swift` — the LAST WORK DONE section; `.task` keyed on a
  `DetailLoadKey(node.id, refreshToken)`; reset-on-entry + `Task.isCancelled` guard + sync cache-hit
  fast path; loading/omit states.
- `CLAUDE.md` / `CONTINUE.md` / `docs/superpowers/backlog.md` — status on completion (at merge).
