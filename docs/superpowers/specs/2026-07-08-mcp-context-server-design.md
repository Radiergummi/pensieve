# Pensieve MCP context server — design

**Date:** 2026-07-08
**Status:** Approved; corrected + both design questions resolved + MCP feature scope curated
2026-07-10 (against the actual code, MCP spec `2025-11-25`, Swift SDK `0.12.1`, and Claude Code
client v2.1+). See "Corrections", "Surfaces & feature scope", "Resolved design questions".
Ready for an implementation plan.

## Corrections (2026-07-10, verified against source)

A ground-truth pass found the spec had trusted a **stale `CLAUDE.md`** over the code for
several kernel names. Fixed inline throughout; the substantive ones:

- `makeDefaultLLMProvider(prefsURL:)` and `PensievePaths.preferencesURL()` **do not exist**.
  The real API is `makeDefaultLLMProvider(defaults:cloudConfig:apiKey:)` with preferences
  read via `PensieveDefaults.shared()`. (`CLAUDE.md` line 25 is stale — flag separately.)
- "Recent events for a node" is **`ProjectQueries.status(_:node:limit:)` → `recentEvents`**,
  not `SessionQueries` (which is only an `isIngested` dedup guard).
- `NextQueries.ranked(_:now:)` has **no `limit`, no `context` filter, and no cited loose end** —
  it returns *all* active nodes with only a loose-end *count* (`NextItem`). `whats_next` must
  slice, filter, and separately call `LooseEndQueries.open` for the top cited loose end. It
  also takes a `DatabaseWriter`, so it needs adapting for the read-only handle.
- The `NarrationCache` key must be **`NarrationCacheKey.make(events:provider:)`** (event-*set* +
  `extractedAt` + **provider**), **not** `nodeID + latestEventID` — the latter is explicitly
  warned against in `NarrationCacheKey.swift` (nondeterministic `occurredAt` ties) and drops the
  provider dimension a prior code-review fixed.
- No read-only CLI DB opener exists (`openCanonical()` returns a *writer* + migrates); add a thin
  `openCanonicalReadOnly()` = `PENSIEVE_DB` → `openCanonicalDatabaseReadOnly(at:)`.
- Path→node resolution must compute the **git common-dir** from cwd first (sources are keyed on
  `…/.git`, not the working dir), exactly as `CaptureSessionStart` does via `Git.commonDir`.
- The MCP SDK dependency must be scoped to the **`pensieve` executable target only**, never
  PensieveKit (else the app drags in the JSON-RPC stack).

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

- Feed grounded, cwd-weighted historic context into a Claude Code session across **three
  triggers** (see "Surfaces" below): ambiently at session start, on-demand when the model
  pulls, and on-demand when the **user deliberately attaches** a project's context.
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
- No full-text search tool.
- No new persisted state in the canonical store or capture spool.
- **No sampling.** A server *could* borrow the client's model via `sampling/createMessage`
  — but **Claude Code does not implement the client `sampling` capability** (verified
  2026-07-10), and it would be circular anyway (asking the caller's model to narrate context
  *for* the caller's model). Revisit only if Pensieve.app itself ever becomes an MCP *host*.
- **No elicitation, resource subscriptions, prompts-completion-heavy flows, logging,
  progress/cancellation, tasks, pagination, or OAuth.** A local, single-user, stdio,
  millisecond-read server has no auth boundary, no long-running work, and no need to ask the
  user structured questions (`os.Logger` already covers observability). See "Surfaces &
  feature scope" for the reasoning and the one fast-follow (prompts).

## Decisions (from brainstorm)

1. **Three surfaces.** MCP tools are pull-only — a server can't push context unprompted.
   Ambient priming is therefore a **SessionStart hook** (`additionalContext`), not the MCP
   server. And a curation pass (2026-07-10) against the live MCP spec + Swift SDK + Claude
   Code's actual client capabilities added a third: **MCP resources** the *user* attaches.
   So the design is three thin surfaces over the same kernel (see "Surfaces & feature scope").
2. **cwd-first weighting.** Prime with the node bound to the working directory; global
   ranked "what's next" is available on-demand.
3. **Prose everywhere, on-device.** All surfaces generate prose via
   `makeDefaultLLMProvider()` — Foundation Models on-device by default (what the app
   uses today), `claude -p` only as fallback. Pensieve owning the prose keeps the MCP
   server **client-agnostic** (doesn't assume the caller is a strong model). Cached to
   control latency.

## Surfaces & feature scope

The context reaches Claude Code through **three complementary triggers**, differing only in
*who* pulls and *when* — all rendering the same `ProjectContextBundle` kernel:

| Surface | Who triggers | Mechanism | Component |
|---------|-------------|-----------|-----------|
| **Ambient** | automatic, at session start | SessionStart hook → `additionalContext` | 3 (`prime`) |
| **User-attach** | the user, deliberately | MCP **resource** (`@pensieve:pensieve://node/{id}`) | 2b (resources) |
| **Model-pull** | the model, mid-task | MCP **tools** (`project_context`, `whats_next`) | 2a (tools) |

Why the user-attach surface matters (and why the original two-tool cut under-served it): the
core workflow is *"I'm sitting down to resume project X — load where it stands."* That is
**user-driven** — the human knows the project. Tools leave invocation to the model's
discretion; a **resource the user `@`-mentions** matches the actual intent far better. It is
also cheap: not a new kernel, just a second thin MCP exposure of the bundle the tools already
return, reusing the existing **`pensieve://` scheme + `DeepLink` router**.

**Curation decisions (verified 2026-07-10 against MCP spec `2025-11-25`, Swift SDK `0.12.1`,
Claude Code client v2.1+):**

- **Adopt: resources over `pensieve://`** (Component 2b) — Claude Code supports `@`-mention
  resource attachment + resource templates. Highest workflow-fit addition.
- **Adopt: roots-based auto-scoping** on `project_context` — Claude Code advertises `roots`
  (v2.1.203+), so the server can resolve the workspace dir and make `path` optional (a
  zero-arg "reload wherever I am"). Keep `path`/`node_id` as fallback for older clients.
- **Adopt: `_meta["anthropic/maxResultSizeChars"]`** on tool/resource results — the one tool
  hint Claude Code *actually* reads (its client ignores the standard `readOnlyHint` /
  `outputSchema` / `structuredContent`). Bounds a large `project_context` payload (500KB
  ceiling). Set standard `readOnlyHint: true` too for client-agnostic hygiene — but expect
  **no** Claude Code effect from it.
- **Fast-follow, not v1: prompts** as `/mcp__pensieve__…` slash commands (+ completion). A
  fourth pull path; redundant once ambient + resources + tools ship. Also Claude Code's
  in-UI use of `completion/complete` is unconfirmed, so the autocomplete payoff is uncertain.
- **Dead / YAGNI:** sampling (unsupported + circular), elicitation, subscriptions, logging,
  progress/cancellation, tasks, pagination, OAuth — see Non-goals.

## Architecture

Same pattern as CLI/app: all logic in tested PensieveKit; the surfaces are thin.

```
                    ┌─────────────────────────────┐
                    │  PensieveKit (tested)        │
   canonical  ─────►│  SessionContextQueries       │  ← the ONE new kernel
   store (RO)       │   • bundle(forPath:) / global │    composes existing:
                    │   • cited loose ends          │    NextQueries, LooseEndQueries,
                    │  SummaryBuilder.narrate       │    NodeFacts, ProvenanceQueries,
                    │  NarrationCache               │    ProjectQueries.status
                    │  makeDefaultLLMProvider()     │
                    └──────┬───────────────┬───────┘
                           │               │
              ┌────────────▼───┐   ┌───────▼──────────────────────┐
   PUSH ◄─────┤ `pensieve      │   │ `pensieve mcp` stdio server  ├──► PULL
   (ambient)  │  prime` hook   │   │  tools:  whats_next,         │  (model &
              │ SessionStart   │   │          project_context     │   user)
              │ →additionalCtx │   │  resources: pensieve://node/…│
              └────────────────┘   └──────────────────────────────┘
```

Two **new** thin subcommands in the existing `pensieve` CLI target (no new binary),
both reading the canonical store **read-only** via a new `openCanonicalReadOnly()` helper
(`PENSIEVE_DB` override → `openCanonicalDatabaseReadOnly(at:)`; the existing `openCanonical()`
returns a *writer* and runs migrations, so it can't be reused):

- **`pensieve prime`** — a *new* SessionStart hook, **separate from** the sacred
  `capture-session-start` so the fast fire-and-forget capture path is untouched.
- **`pensieve mcp`** — a long-lived stdio MCP server exposing **tools** (2a) and
  **resources** (2b), registered via `claude mcp add pensieve -- pensieve mcp`. Each
  tool/resource call opens a **fresh read transaction** (WAL read sees the latest committed
  drain; never memoize a stale bundle across the external daemon's writes).

**Transport decision:** use the official **MCP Swift SDK**
(`modelcontextprotocol/swift-sdk`) rather than hand-rolling JSON-RPC — matches the
"platform primitives first" principle. Verify its maturity during planning; fall back
to a minimal hand-rolled stdio JSON-RPC (the tools subset is small) only if the SDK is
heavy or drags in unwanted dependencies. **Scope the SDK dependency to the `pensieve`
executable target only** — never PensieveKit, or the app inherits the whole JSON-RPC stack.

## Component 1 — `SessionContextQueries` (new Kit kernel, tested, read-only)

The single source of truth for "what's the grounded state." Two entry points:

```swift
static func bundle(forPath path: String?, db) throws -> ProjectContextBundle?
    // git-common-dir(path) → source.key → node; nil if the path binds to no node
static func ranked(limit: Int, context: NodeContext?, db) throws -> [NextItem]
    // NOT a pass-through: NextQueries.ranked returns ALL active nodes, no limit/context.
    // This kernel filters by context, slices to limit, and joins each node's top
    // cited loose end from LooseEndQueries.open (NextItem carries only a count).
```

`ProjectContextBundle` — all grounded, composed from existing kernels:

- **node facts** — name, kind, description, context (work/personal) — via `NodeFacts`
- **open loose ends** — each with its **verbatim quote + provenance** (source event,
  transcript pointer) via `LooseEndQueries` / `ProvenanceQueries` — *inside the gate*
- **recent events** — last N git commits / sessions via `ProjectQueries.status(_:node:limit:)`
  (`recentEvents`), *not* `SessionQueries`
- **dormancy + next-score** — `daysDormant`, `openLooseEnds` (a *count*), `score` from
  `NextQueries` (`NextItem`); the cited loose-end *text* comes from `LooseEndQueries.open`
- **prose recap** — `String?` from `SummaryBuilder.narrate`, best-effort — *outside the
  gate, `nil` on failure/no-events*

**Path→node resolution** — no read-only `nodeID(forPath:)` exists yet (the only resolver,
`ProjectResolver.resolve`, is a find-*or-create* writer). Add a thin **read-only** tested one
in this kernel. **Critical caveat:** git sources are keyed on the canonicalized git
**common-dir** (`…/.git`), *not* the working directory — a raw cwd will match nothing. The
resolver must compute the common-dir first via `Git.commonDir` (exactly as
`CaptureSessionStart.swift` does), then match `Source.key == canonical(commonDir)` →
`Source.nodeID` → `Node`. No new schema.

## Component 2a — `pensieve mcp` tools (model-pull)

Long-lived stdio JSON-RPC server. Reads canonical store read-only. Two tools:

| Tool | Params | Returns |
|------|--------|---------|
| `project_context` | `path` (**optional** — see roots below), or `node_id` | one `ProjectContextBundle` — "reload *this* project" |
| `whats_next` | `limit` (default 5), `context?` (work/personal) | ranked nodes across everything: score breakdown (open loose ends, days dormant) + each node's top cited loose end |

Design notes:
- `loose_ends` is folded into `project_context` (not its own tool).
- No write tools, no search (YAGNI).
- **Roots-based auto-scoping.** When `path` and `node_id` are both omitted, resolve the
  current workspace via the client's **`roots`** capability (`roots/list` → the launch/`--add-dir`
  directories; Claude Code v2.1.203+) and scope to the node bound to it — a zero-arg "reload
  wherever I am." Fall back to the process cwd if the client advertises no roots (older
  clients), and `path`/`node_id` always override. This reuses Component 1's git-common-dir
  path→node resolver.
- **Result-size hint.** Set `_meta["anthropic/maxResultSizeChars"]` on the `project_context`
  result (the one hint Claude Code's client actually honors; 500KB ceiling) so a project with
  many loose ends can't blow the caller's context. Also set standard `readOnlyHint: true` for
  client-agnostic hygiene — but expect **no** Claude Code effect (its client ignores it, and
  `outputSchema`/`structuredContent` too).
- **Prose is cached-first, then bounded, never blocking** (resolves OQ2). `project_context`:
  (1) always returns the grounded bundle (facts + cited loose ends + dormancy) — pure query,
  instant; (2) fills `prose` from the `NarrationCache` if present — free; (3) on a miss,
  attempts a synchronous narrate bounded by a **hard timeout (~3s)**, returning `prose: nil`
  on timeout and **writing through** on success. FM cold-start can be ≫ the naive 1–2s, and
  the caller is blocking on the result, so the timeout is load-bearing, not decorative. `nil`
  never becomes a facts-dump (trust gate). In-process it also memoizes within a fresh read
  transaction so repeated calls in one session are free.

## Component 2b — `pensieve mcp` resources (user-attach)

Same server, exposing the bundle as **user-attachable MCP resources** — the surface that best
fits "I'm resuming project X, load it" (the *user* chooses, not the model). Reuses the
existing **`pensieve://` scheme** (already a `DeepLink` route). All served as `text/markdown`
so the existing prose/quote formatting renders.

| Resource | Kind | Content |
|----------|------|---------|
| `pensieve://node/{id}` | **template** (RFC 6570) | one node's `ProjectContextBundle` rendered markdown — the same bundle 2a returns |
| `pensieve://smartlist/whats-next` | static | the ranked "what's next" list rendered markdown |
| `pensieve://briefing` | static (optional) | the by-project briefing map |

Design notes:
- **Same kernel, same trust gate, same cached-first→bounded→`nil` prose** as 2a — a resource
  read is user-triggered, so a synchronous narrate-under-timeout is fine and writes through.
- Register the `node` **resource template** so a user `@`-mentions any project by id; the
  static smart-list/briefing resources are one-click "attach my whole queue."
- Apply the same `anthropic/maxResultSizeChars` bound.
- **Fast-follow (not v1): prompts** — expose `/mcp__pensieve__reload <project>` etc. as MCP
  prompts with node-name argument completion. Deferred: redundant with three surfaces already,
  and Claude Code's in-UI `completion/complete` behavior is unconfirmed.

## Component 3 — `pensieve prime` (SessionStart hook, ambient push)

Emits `additionalContext` at session start: the cwd's `project_context` bundle rendered
compact — facts, cited loose ends, dormancy, and cached prose *if present*. If the cwd
binds to no node, it emits **nothing** (silent — no noise on unrelated repos).

**Read-only, never spawns** (resolves OQ1). `pensieve prime` runs synchronously before the
turn — whatever it prints to stdout *is* the session-start delay — so it is a **pure query**:

1. Emit facts + cited loose ends **immediately** (no model).
2. Emit prose **only if already cached**; otherwise omit it. The hook **never narrates and
   never spawns a background process** — a CLI that `exit()`s can't keep a thread alive, and a
   detached child that inherits stdout would hang session start until it finishes. That whole
   hazard is designed out.

Net: `prime` is as fast and unbreakable as `capture-session-start`. The cache is warmed by
real `project_context` pulls (Component 2a, synchronous write-through) and by the app — so
prose appears on `prime` once you've interacted with a node through either surface. Reliably
warming *ambient* prose without any prior interaction is a **deferred follow-up** (have the
existing `com.pensieve.sync` launchd daemon narrate recently-active nodes into the shared
cache — a real long-lived process, the safe place for background narration).

**Register on `compact` too, not just `startup`/`resume`/`clear`.** SessionStart hooks are
matcher-scoped and fire on `compact` — since the docs frame hooks as ideal for *dynamic
regeneration*, matching `compact` **re-injects the grounded context after a compaction wipes
it**, keeping long sessions primed for free.

## Component 4 — `NarrationCache` (new, disposable, standalone)

A small standalone store: `~/Library/Application Support/Pensieve/narration-cache.sqlite`,
keyed by **`NarrationCacheKey.make(events:provider:)`** (the existing, tested key:
event-ID *set* + `extractedAt` + **provider**) `→ prose`.

- **Deliberately not** the canonical store (whose only writer stays `Ingester.drain()`)
  and **not** the capture spool — a derived, disposable cache.
- Reusing `NarrationCacheKey` means any new commit/session **auto-invalidates** (the event
  set changes → old key misses → re-narrate) AND a provider switch invalidates too. Do **not**
  key on `nodeID + latestEventID`: `NarrationCacheKey.swift` warns that "latest event" is
  nondeterministic under `occurredAt` ties, and it would drop the provider dimension a prior
  code-review deliberately added.
- Losing/deleting the file costs nothing but a re-narrate.
- Writers: `pensieve mcp` (write-through on a successful bounded narrate) and — later — the
  sync daemon (deferred). Readers: `pensieve mcp`, `pensieve prime` (read-only). The existing
  app cache (`AppModel`, in-memory + UserDefaults) is separate and stays as-is; this store
  exists only to share prose *across processes* (app ⇄ CLI ⇄ MCP).

## Resolved design questions (2026-07-10)

**OQ1 — `pensieve prime` is read-only; it never warms the cache.** Spawning a detached
narration from a hook is a lifecycle trap (a `exit()`ing CLI can't keep a thread alive; a
detached child inheriting stdout hangs session start). Designed out: `prime` emits facts +
cited loose ends + prose-*if-cached* and nothing else. Reliable ambient prose is a deferred
follow-up owned by the sync daemon (below), not the hook.

**OQ2 — MCP prose is cached-first → bounded (~3s) → `nil`, never blocking.** The consumer is a
frontier model, so on-device FM prose is a nicety, not the payload — the grounded cited loose
ends + ranked next are. So the bundle always returns instantly; prose is served from cache when
warm and attempted under a hard timeout on a miss, `nil` otherwise. This also removes OQ1's
warming pressure (real pulls warm the cache via write-through).

## Trust gate

Unchanged and reaffirmed. Loose ends carry real quotes + provenance (inside the gate).
Prose is best-effort, `nil` on no-events/provider-failure — a facts-dump is never
substituted. Exactly the boundary the app already draws for "Last Work Done" and strand
naming.

## Testing

- **`SessionContextQueries`** + path→node resolution — fully unit-tested in PensieveKit
  against seeded temp stores (`PENSIEVE_DB`): bundle for a bound path, `nil` for an
  unbound path (incl. a git dir whose common-dir binds to no source), cited loose ends
  present, ranked filtered-and-sliced (context filter + limit honored).
- **`NarrationCache`** — unit-tested: put/get round-trip, miss on a changed event set /
  changed provider (auto-invalidation via `NarrationCacheKey`), tolerant of a
  missing/corrupt cache file.
- **`pensieve mcp` tools** — smoke test driving real stdio JSON-RPC: `initialize` →
  `tools/list` (asserts the two tools) → `tools/call project_context` against a seeded
  store, asserting the JSON bundle shape.
- **`pensieve mcp` resources** — smoke test: `resources/templates/list` asserts the
  `pensieve://node/{id}` template; `resources/read` on a seeded node id returns the
  markdown bundle; `resources/list` asserts the static smart-list resource.
- **`pensieve prime`** — smoke test asserting the emitted `additionalContext` for a
  seeded cwd, and that it emits **nothing** for an unbound path.

The CLI subcommands and MCP wiring stay thin; all derivation logic lives in tested Kit.

## Human-verify carries (need the built CLI + a real store)

- `claude mcp add pensieve -- pensieve mcp`, then a real Claude Code session: confirm
  `project_context` and `whats_next` are callable and return grounded bundles.
- **Resources:** confirm `@pensieve:pensieve://node/<id>` autocompletes and attaches a node's
  grounded context, and that the static `whats-next` resource attaches. Confirm the markdown
  renders (prose/quotes).
- **Roots:** on Claude Code v2.1.203+, confirm a **zero-arg** `project_context` (no `path`)
  scopes to the current workspace via `roots/list`; confirm the cwd fallback on an older client.
- Register `pensieve prime` as a SessionStart hook; confirm ambient context appears and
  that session start is not visibly slowed (facts + cited loose ends immediate; prose appears
  once the node has been pulled via `project_context` or opened in the app — `prime` never
  narrates).
- Confirm on-device FM path is taken (not `claude -p`) on this machine, and that the
  narration cache invalidates after a new commit/session.

## Out of scope / deferred

- **Ambient-prose warming via the sync daemon** (resolves OQ1's "prose without prior
  interaction"): have `com.pensieve.sync` narrate recently-active nodes into the shared
  `NarrationCache` as a side effect of its 300s drain. Deferred follow-up — the safe home for
  background narration (a real long-lived process), out of scope for this cut.
- **MCP prompts** (`/mcp__pensieve__reload <project>` + node-name completion) — a fourth pull
  path, fast-follow once the three v1 surfaces prove out (see "Surfaces & feature scope").
- Write tools over MCP; full-text search.
- Weighting refinements beyond cwd-first (e.g. blended global+local score).
- MCP features Claude Code doesn't consume or a local tool doesn't need: sampling,
  elicitation, resource subscriptions, logging, progress/cancellation, tasks, pagination,
  OAuth (reasons in Non-goals).
- Exposing the same surfaces to other MCP clients is *supported* by the client-agnostic
  design but not separately verified here.
