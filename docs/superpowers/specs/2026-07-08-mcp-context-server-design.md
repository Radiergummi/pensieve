# Pensieve MCP context server — design

**Date:** 2026-07-08
**Status:** Approved (brainstorm complete, ready for implementation plan)

## Problem

Pensieve currently *consumes* Claude Code — it captures sessions and commits into
the canonical store and derives intelligence (deterministic "next" ranking, open
loose ends with provenance, grounded "last work done" prose). But that intelligence
only surfaces in Pensieve's own app/CLI. To reload context on a project you have to
*manually conjure it* — open the app, run `pensieve next`.

This design closes the loop: Pensieve becomes a **provider back to Claude Code**, so
the context it already derives flows into the tool that generated the raw material —
weighted toward whatever repo you're sitting in — without you having to ask for a
specific past project by name.

## Goals

- Feed grounded, cwd-weighted historic context into a Claude Code session **both**
  ambiently (at session start) and on-demand (mid-session tool calls).
- Weight toward the **current repo/cwd first**: prime with the project bound to the
  working directory; make the global "what's next" available on-demand.
- Serve **prose recaps** (not just facts) so context reload needs no re-reading, while
  keeping loose ends **inside the trust gate** (real quotes + provenance) and prose
  **best-effort outside it** (`nil` on failure, never a facts-dump) — the exact
  boundary the app's "Last Work Done" already draws.
- Stay **thin over tested PensieveKit**, like the CLI and app targets.
- Never block or slow Claude Code session start; never touch the sacred capture path
  or the single-writer canonical store.

## Non-goals (YAGNI)

- No write tools over MCP (no organizing the tree, no closing loose ends remotely).
  The MCP surface is read-only; the only canonical writer stays `Ingester.drain()`.
- No full-text search tool, no node-tree resource — two tools cover "where am I" and
  "where should I go."
- No new persisted state in the canonical store or capture spool.

## Decisions (from brainstorm)

1. **Both surfaces.** MCP tools are pull-only — a server can't push context unprompted.
   Ambient priming is therefore a **SessionStart hook** (`additionalContext`), not the
   MCP server. So "both" decomposes into two thin surfaces over the same kernels.
2. **cwd-first weighting.** Prime with the node bound to the working directory; global
   ranked "what's next" is available on-demand.
3. **Prose everywhere, on-device.** Both surfaces generate prose via
   `makeDefaultLLMProvider()` — Foundation Models on-device by default (what the app
   uses today), `claude -p` only as fallback. Pensieve owning the prose keeps the MCP
   server **client-agnostic** (doesn't assume the caller is a strong model). Cached to
   control latency.

## Architecture

Same pattern as CLI/app: all logic in tested PensieveKit; the surfaces are thin.

```
                    ┌─────────────────────────────┐
                    │  PensieveKit (tested)        │
   canonical  ─────►│  SessionContextQueries       │  ← the ONE new kernel
   store (RO)       │   • bundle(forPath:) / global │    composes existing:
                    │   • cited loose ends          │    NextQueries, LooseEndQueries,
                    │  SummaryBuilder.narrate       │    NodeFacts, ProvenanceQueries,
                    │  NarrationCache               │    SessionQueries
                    │  makeDefaultLLMProvider()     │
                    └──────┬───────────────┬───────┘
                           │               │
              ┌────────────▼───┐   ┌───────▼────────────────┐
   PUSH ◄─────┤ `pensieve      │   │ `pensieve mcp`         ├────► PULL
   (ambient)  │  prime` hook   │   │  stdio MCP server      │   (on-demand
              │ SessionStart   │   │  tools: whats_next,    │    tool calls)
              │ →additionalCtx │   │         project_context│
              └────────────────┘   └────────────────────────┘
```

Two **new** thin subcommands in the existing `pensieve` CLI target (no new binary),
both reading the canonical store **read-only**:

- **`pensieve prime`** — a *new* SessionStart hook, **separate from** the sacred
  `capture-session-start` so the fast fire-and-forget capture path is untouched.
- **`pensieve mcp`** — a long-lived stdio MCP server, registered via
  `claude mcp add pensieve -- pensieve mcp`.

**Transport decision:** use the official **MCP Swift SDK**
(`modelcontextprotocol/swift-sdk`) rather than hand-rolling JSON-RPC — matches the
"platform primitives first" principle. Verify its maturity during planning; fall back
to a minimal hand-rolled stdio JSON-RPC (the tools subset is small) only if the SDK is
heavy or drags in unwanted dependencies.

## Component 1 — `SessionContextQueries` (new Kit kernel, tested, read-only)

The single source of truth for "what's the grounded state." Two entry points:

```swift
static func bundle(forPath path: String?, db) throws -> ProjectContextBundle?
    // canonicalized path → source → node; nil if the path binds to no node
static func ranked(limit: Int, context: NodeContext?, db) throws -> [NextItem]
    // thin pass-through to NextQueries (already tested)
```

`ProjectContextBundle` — all grounded, composed from existing kernels:

- **node facts** — name, kind, description, context (work/personal) — via `NodeFacts`
- **open loose ends** — each with its **verbatim quote + provenance** (source event,
  transcript pointer) via `LooseEndQueries` / `ProvenanceQueries` — *inside the gate*
- **recent events** — last N git commits / sessions via `SessionQueries`
- **dormancy + next-score** — `daysDormant`, `openLooseEnds`, `score` from `NextQueries`
- **prose recap** — `String?` from `SummaryBuilder.narrate`, best-effort — *outside the
  gate, `nil` on failure/no-events*

**Path→node resolution** reuses Pensieve's existing canonicalized-path → source → node
attribution. If no direct `nodeID(forPath:)` resolver exists yet, add a thin tested one
in the same kernel (it composes existing source/attribution queries; no new schema).

## Component 2 — `pensieve mcp` (stdio MCP server)

Long-lived stdio JSON-RPC server. Reads canonical store read-only. Two tools:

| Tool | Params | Returns |
|------|--------|---------|
| `project_context` | `path` (default cwd), or `node_id` | one `ProjectContextBundle` — "reload *this* project" |
| `whats_next` | `limit` (default 5), `context?` (work/personal) | ranked nodes across everything: score breakdown (open loose ends, days dormant) + each node's top cited loose end |

Design notes:
- `loose_ends` is folded into `project_context` (not its own tool).
- No write tools, no search, no tree resource (YAGNI).
- `project_context` narrates **synchronously** — the caller is already awaiting a tool
  result, so ~1–2s of on-device FM is acceptable — and **writes through** to the
  narration cache. In-process it also memoizes so repeated calls in one session are free.

## Component 3 — `pensieve prime` (SessionStart hook, ambient push)

Emits `additionalContext` at session start: the cwd's `project_context` bundle rendered
compact — facts, cited loose ends, dormancy, and cached prose *if present*. If the cwd
binds to no node, it emits **nothing** (silent — no noise on unrelated repos).

**Non-blocking prose (serve-cached, warm-in-background).** `pensieve prime` runs
synchronously before the turn — whatever it prints to stdout *is* the session-start
delay. So it must never block on the model:

1. Emit facts + cited loose ends **immediately** (pure query, no model), plus prose
   **only if already cached**.
2. Spawn a **detached** narration to populate the cache for next time, then exit without
   waiting.

Net: the hook never blocks on FM/`claude -p`; prose appears from the second session start
onward in a given `nodeID + latestEventID` state. `project_context` (Component 2) fills
the cache synchronously on its first call, so an on-demand pull also warms it.

## Component 4 — `NarrationCache` (new, disposable, standalone)

A small standalone store: `~/Library/Application Support/Pensieve/narration-cache.sqlite`,
keyed `nodeID + latestEventID → prose`.

- **Deliberately not** the canonical store (whose only writer stays `Ingester.drain()`)
  and **not** the capture spool — a derived, disposable cache.
- Keying on `latestEventID` means any new commit/session **auto-invalidates**: new
  activity → the old key misses → prose is re-narrated. No manual invalidation.
- Losing/deleting the file costs nothing but a re-narrate.
- Read/write by both `pensieve prime` (background warm) and `pensieve mcp` (write-through).

## Trust gate

Unchanged and reaffirmed. Loose ends carry real quotes + provenance (inside the gate).
Prose is best-effort, `nil` on no-events/provider-failure — a facts-dump is never
substituted. Exactly the boundary the app already draws for "Last Work Done" and strand
naming.

## Testing

- **`SessionContextQueries`** + path→node resolution — fully unit-tested in PensieveKit
  against seeded temp stores (`PENSIEVE_DB`): bundle for a bound path, `nil` for an
  unbound path, cited loose ends present, ranked pass-through.
- **`NarrationCache`** — unit-tested: put/get round-trip, miss on new `latestEventID`
  (auto-invalidation), tolerant of a missing/corrupt cache file.
- **`pensieve mcp`** — smoke test driving real stdio JSON-RPC: `initialize` →
  `tools/list` (asserts the two tools) → `tools/call project_context` against a seeded
  store, asserting the JSON bundle shape.
- **`pensieve prime`** — smoke test asserting the emitted `additionalContext` for a
  seeded cwd, and that it emits **nothing** for an unbound path.

The CLI subcommands and MCP wiring stay thin; all derivation logic lives in tested Kit.

## Human-verify carries (need the built CLI + a real store)

- `claude mcp add pensieve -- pensieve mcp`, then a real Claude Code session: confirm
  `project_context` and `whats_next` are callable and return grounded bundles.
- Register `pensieve prime` as a SessionStart hook; confirm ambient context appears and
  that session start is not visibly slowed (facts immediate; prose from the 2nd start).
- Confirm on-device FM path is taken (not `claude -p`) on this machine, and that the
  narration cache invalidates after a new commit/session.

## Out of scope / deferred

- Write tools over MCP; full-text search; node-tree resource/prompts.
- Weighting refinements beyond cwd-first (e.g. blended global+local score).
- Exposing the same tools to other MCP clients is *supported* by the client-agnostic
  design but not separately verified here.
