# Pensieve.app v0.1 — Heartbeat Window (Design)

**Date:** 2026-07-04. **Status:** approved in brainstorming, ready for a plan.

## Goal

Give Moritz a native macOS window that, at a glance, shows **Pensieve is alive and collecting
his work** — a single "heartbeat" screen — so he can confidently turn on continuous capture
(dogfood) knowing the plumbing is connected. This is the *first window of the real product*, not
a throwaway monitor.

## Framing: this is `Pensieve.app`, starting minimal

The intended end-state (spec §Later / CLAUDE.md) is three faces over one shared `PensieveKit`
kernel:

- **`Pensieve.app`** — the SwiftUI product (eventually three-pane, Mela-like).
- **`pensieved`** — a background service that drains/ingests on its own.
- **`pensieve` CLI** — the companion for capture + scripted ingestion (already built).

This spec builds **`Pensieve.app` v0.1**: one window showing a heartbeat. The menu-bar item and,
later, the three-pane views grow **in the same app target** — nothing here is discarded. The
liveness/counts logic lives in `PensieveKit` precisely because `pensieved` will later call the
same code to decide what to ingest. **The daemon is not built in this phase**; capture remains
dumb git/session hooks → spool, and ingestion remains manual `pensieve ingest`. The heartbeat
window watches the **capture spool**, so it proves capture is firing *even before any daemon or
ingest runs*.

## Non-goals (YAGNI — explicitly deferred)

- Recent-activity feed, per-project rows, loose-end display, any three-pane content.
- Menu-bar item / `LSUIElement` / app bundle / code signing (next step, own spec).
- `pensieved` background service; auto-ingest; triggering ingestion from the app.
- Any *write* to either store. The window is strictly read-only.
- iOS, CloudKit, widgets.

## Architecture — two pieces, cleanly split

### 1. `MonitorSnapshot` (in `PensieveKit`, pure + testable)

The only part with logic and tests. A value type plus a gather function that reads the two stores
(read-only) and computes the heartbeat:

```swift
public struct MonitorSnapshot: Equatable, Sendable {
  public enum Status: Equatable, Sendable { case active, idle, notSetUp }
  public let status: Status
  public let lastCaptureAt: Date?      // newest spool row ts (any kind), nil if none/unreachable
  public let spoolPending: Int         // captures with ingested = 0
  public let eventCount: Int           // canonical events
  public let looseEndCount: Int        // canonical loose ends with status == "open"
}
```

- `gather(canonicalURL:spoolURL:now:activeWithin:)` opens each store read-only, computes the
  fields, and never throws out to the caller — any unreachable/missing store degrades to
  `.notSetUp` with nil/zero fields (this is the expected pre-dogfood state, not an error).
- **Status rule** (spool-driven, so it reassures during the pre-ingest window — hooks firing but
  `ingest` not yet run; threshold `activeWithin` default **15 min**):
  - nothing captured *and* nothing ingested (no spool captures, `spoolPending == 0`, and
    `eventCount == 0`) → `.notSetUp`
  - `lastCaptureAt` within `activeWithin` of `now` → `.active` (even if the canonical store
    doesn't exist yet — capture is working before the first ingest)
  - otherwise (something exists, but the last capture is old) → `.idle`  ← the normal resting
    state; capture is event-driven, so `.active` only lights up right after a commit / session start.

### 2. `PensieveApp` app target (new executable, thin render)

A new SwiftPM `executableTarget` named **`PensieveApp`** (product `PensieveApp`) depending on
`PensieveKit`. ~40 lines of SwiftUI/AppKit: an `NSApplication` hosting one `NSWindow` with an
`NSHostingView`. A `Timer` fires every **3 s**, calls `MonitorSnapshot.gather(...)`, and updates
an `@Observable`/`ObservableObject` the view renders. No business logic in the target. (Target
renamed from `Pensieve` to avoid a case-insensitive-APFS collision with the `pensieve` CLI target.)

The window renders the agreed minimal layout:

```
╭─ Pensieve ──────────────────╮
│ ● active                    │   ● active (green) / ○ idle (grey) / ⚠ not set up (amber)
│ last capture 2 min ago      │   omitted / "no captures yet" when lastCaptureAt == nil
│                             │
│ Spool:  3 pending           │
│ Events: 214                 │
│ Loose ends: 12              │
╰─────────────────────────────╯
```

## Supporting change: two read-only spool helpers

`CaptureSpool` currently exposes `pending()` (full rows, un-ingested only). Add two cheap
read-only queries so the snapshot doesn't reach past the spool's API:

- `func lastCaptureAt() -> Date?` — `SELECT max(ts) FROM captures` (any kind, **including
  already-ingested** rows, so "last capture" survives an ingest). Parsed with the same
  whole-second ISO strategy the spool writes with.
- `func pendingCount() -> Int` — `SELECT count(*) FROM captures WHERE ingested = 0` (avoids
  materializing rows just to count them).

## Data flow

```
git/session hooks ─▶ capture spool (ts, ingested)      ┐
pensieve ingest ───▶ canonical store (events, loose)   │
                                                        ▼
        MonitorSnapshot.gather(canonicalURL, spoolURL, now)  ──▶ Snapshot
                                                        │
                              Timer(3s) in Pensieve app ┘  ──▶ SwiftUI render
```

## Paths & environment

`gather` takes explicit store URLs. The app resolves them via `PensievePaths` defaults, honoring
`PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` overrides — identical to the CLI — so throwaway/temp stores
(and tests) point the window wherever needed.

## Concurrency & the sacred capture path

Reads are **read-only** and both stores are **WAL**, so the window never blocks a hook append or
an ingest. If a store is momentarily locked or absent, `gather` degrades to `.notSetUp` for that
tick rather than throwing. No `static` mutable `ISO8601` formatters (Swift 6). The app never
writes.

## Testing

- **`MonitorSnapshotTests`** (the real coverage): seed a temp canonical store + temp spool, then
  assert `gather` returns the expected counts and status:
  - empty / missing canonical store → `.notSetUp`.
  - spool row `now` → `.active`; spool row 30 min old (with `activeWithin: 15*60`) → `.idle`.
  - `lastCaptureAt` reflects the newest row **even after it's marked ingested** (regression guard
    for the "survives ingest" requirement).
  - `spoolPending` counts only `ingested = 0`; `eventCount`/`looseEndCount` match seeded rows;
    `looseEndCount` counts only `status == "open"`.
- **`CaptureSpool` helper tests**: `lastCaptureAt`/`pendingCount` against a seeded spool.
- The SwiftUI target is not unit-tested (thin render); its correctness is the manual
  window-appears check below.

## Packaging & how to run

- `swift run PensieveApp` launches the window (dev workflow for now).
- **First implementation step must verify the window actually appears** when launched as an
  unbundled SwiftPM executable (compile+link already confirmed in a spike; runtime display of an
  unbundled `NSApplication` window is the one open risk). If an unbundled window misbehaves
  (dock/focus/activation), the fallback is a minimal hand-written `.app` bundle wrapper — still no
  Xcode required. This risk, and the Xcode.app decision, are revisited at the menu-bar step, not
  here.

## Open constraints

- **Command Line Tools only (no Xcode.app).** SwiftUI compiles/links under CLT (verified). Build
  the app with `swift build`/`swift run`; `PensieveKit` tests still run via `./scripts/test.sh`.
- Disk runs tight; on a SwiftSyntax/macro linker error, `rm -rf .build` and retry.

## Self-review

- **Placeholders:** none — every component has a concrete type/interface.
- **Consistency:** status logic, the Snapshot fields, and the rendered layout agree; the
  three-faces framing matches CLAUDE.md's "Later" section; the spool additions match its real
  schema (`ts`, `ingested`).
- **Scope:** single window, one pure function, two spool helpers, one thin target — small enough
  for one plan.
- **Ambiguity:** "last capture" is pinned to the spool's newest row (any kind, incl. ingested),
  not canonical `occurredAt` (which is *work* time, not *capture* time).
```
