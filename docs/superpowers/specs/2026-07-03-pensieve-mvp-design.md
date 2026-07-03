# Pensieve — MVP Design

**Date:** 2026-07-03
**Status:** Approved design. **Phase 1A (capture & ingest) is implemented and merged to `main`** — see `../phase-1a-outcome.md` for what shipped and the concrete design inputs for Phase 1B (the intelligence layer, next up). This document remains the source of truth for overall intent across all phases.
**Audience:** Personal single-user tool (Moritz). Not a product.

## Purpose

Pensieve is a native macOS app that automatically reconstructs *where each of my
parallel projects stands* — with as little manual logging as possible — so an
ADHD brain juggling many efforts can, at any moment, answer:

- What was I doing on project X?
- Is this actually finished, or were there loose ends I never closed?
- What should I work on next?

The hard part of ADHD tooling is capture-without-remembering-to-capture. Pensieve
solves that by riding on artifacts I already produce: **git history** and
**Claude Code session transcripts**. I never have to log anything for the core
loop to work.

## Success criteria

The project lives or dies on one thing: **are the AI-generated project summaries
and "loose ends" trustworthy and useful, or plausible-sounding filler?** Every
design decision below is subordinate to answering that question cheaply and early,
before building UI on top of it.

## Deferred, not abandoned (v1 out of scope — but on the roadmap)

**All of these are intended.** They are simply not in the initial version we are
building now. The implementer must treat them as known destinations: **do not make
choices that foreclose them**, but do not build them yet. Where a design decision
has a cheap way to keep one of these reachable, take it (e.g. project ≠ directory
keeps non-code sources open; the persistence choice keeps CloudKit reachable).

- CloudKit sync and an iOS companion app *(the persistence layer keeps a clean
  on-ramp — see below — but we configure none of it now)*
- Widgets, Lock Screen widgets, Siri/Shortcuts, Spotlight indexing
- FSEvents / real-time file monitoring
- Cross-project dependency graphs, analytics dashboards, token-spend charts
- Non-code source types (browser work, Notion, Entra, etc.) — the model already
  allows them; we implement none in v1

**Genuine non-goal (not wanted, ever):** a Python backend. The always-on
background service *is* part of the design — see below — but it is a native Swift
`SMAppService` agent, not a separate-language network backend.

## Core principle: project ≠ directory

A **Project** is a first-class *area of work*, not a git repo and not a directory.
A git repo is merely one *source* of events feeding a project. This keeps the door
open for "the ISMS in Notion" or "the Entra setup" to be real projects later,
without a schema migration — they'd be new source types emitting events attributed
to a project. We implement only git + Claude-Code source types now, but nothing
assumes `project == repo`.

## Architecture

One Swift codebase. One shared core framework. Two thin front-ends. Two SQLite
files with distinct jobs.

```
   git post-commit/post-checkout hook ─┐
   `pensieve capture ...` (CLI)        ├─► capture.sqlite  (dumb, append-only spool)
                                       │        │
                                       │        │  drained by
                                       │        ▼
                          ingester (in PensieveKit) ──► pensieve.sqlite (canonical, rich)
   Claude Code SessionEnd hook ────────┘   reads ~/.claude/projects/**/*.jsonl        │
   (or app polls transcript mtimes)                                                   │
                                                                       observed by    ▼
                                                             Pensieve.app  +  `pensieve` CLI
```

### Components

- **`PensieveKit`** — Swift framework. Everything real lives here: data model,
  both stores, capture-write, transcript parsing, the ingester, loose-end
  extraction, summary generation. No UI, no CLI-isms. Both front-ends link it.

- **`Pensieve.app`** — the actual product. Native macOS, three-pane layout in the
  spirit of Mela:
  - **Sidebar:** projects + smart lists ("What's Next", "Dormant", "Blocked").
  - **List:** projects, or events within a selected project.
  - **Detail:** the rich view — summary, timeline, loose ends *with their
    provenance*, attached context.
  - (Exact timeline presentation is deliberately left for the app phase.)

- **`pensieve` CLI** — a second thin target over the same `PensieveKit`. It is:
  1. the binary the git/Claude-Code hooks invoke (`pensieve capture-commit`,
     `pensieve ingest-session`), and
  2. a permanent power/debug interface (`pensieve next`, `pensieve status <p>`,
     `pensieve group`, `pensieve checkpoint`).
  The app can be driven from the CLI; the CLI is never the center of gravity.

- **`pensieved` — the always-on background service** (registered via
  `SMAppService`). A first-class, native Swift component (not deferred, not a
  network backend). It is the primary driver of the heavy, off-the-critical-path
  work: watch `~/.claude/projects/**` for new/changed transcripts, drain the
  capture spool, and generate summaries (including a pre-computed morning digest,
  so it's ready before I open the app). It does **not** listen on a socket/port —
  it works entirely through the filesystem and the shared SQLite store. See the
  ingestion guardrails for why capture never depends on it being alive.

### The two databases (spool + canonical)

**`capture.sqlite` — the spool.** Tiny, dumb, append-only. One table:

| column     | notes                                          |
|------------|------------------------------------------------|
| `id`       | autoincrement                                  |
| `ts`       | capture timestamp                              |
| `kind`     | e.g. `git.commit`, `git.checkout`, `cc.session`|
| `payload`  | JSON blob — raw, unenriched                     |
| `ingested` | 0/1 flag                                        |

No foreign keys, no joins, no knowledge of the canonical model. Its schema is
frozen and can outlive many migrations of the canonical store. Purely local;
**never synced**.

**`pensieve.sqlite` — the canonical store** (SQLiteData / GRDB). The rich model,
sole thing that ever gets CloudKit sync (later). Tables:

- `projects` — id, name, state. First-class areas of work.
- `sources` — a git repo or a CC-session-stream. **Bound many-to-one to a
  project.** Auto-created 1:1 per discovered repo; `pensieve group` merges several
  into one project (multi-repo efforts → one area of work).
- `events` — timestamped, from a source, attributed to a project. The enriched
  activity record.
- `loose_ends` — extracted open items. **Each carries provenance**: the source
  event + a verbatim quote. No provenance → the item does not exist.
- `checkpoints` — manual "I was in the middle of X" notes.

## Capture path (must be fast, must never lose data)

- Git hooks are tiny shell scripts installed into tracked repos. We use
  **`post-commit` and `post-checkout`**, which git runs *after* the commit/checkout
  already exists — so the hook is **never on the commit's critical path**.
- The hook calls `pensieve capture ...`, which opens `capture.sqlite`, inserts one
  row, and exits. No IPC, no network, no dependency on any running process, no
  Claude call. Even a cold Swift-binary start is invisible to the user.
- Claude Code sessions: a `SessionEnd` hook fires `pensieve ingest-session <path>`
  which appends a `cc.session` spool row pointing at the transcript; alternatively
  the app/agent polls `~/.claude/projects/**/*.jsonl` mtimes. Either way capture is
  a spool append.

**Guardrail #1:** capture writes to the spool *directly*, never via IPC to an
agent. Capture correctness must never depend on anything being alive.

## Ingestion

The **ingester** is a `PensieveKit` component. In normal operation the always-on
`pensieved` service runs it; the app also runs it on launch/foreground as a
fallback. It drains `capture.sqlite`:

1. Read rows where `ingested = 0`.
2. Enrich: attribute to a project (via source binding, auto-creating a
   project+source for a newly seen repo), parse the git metadata, and for
   `cc.session` rows, parse the transcript.
3. Write enriched `events` (and extracted `loose_ends`) into `pensieve.sqlite`.
4. Mark spool rows `ingested = 1`.

Only the ingester writes the canonical store → **single-writer**, so no write
contention and live UI via GRDB `ValueObservation` is trivial.

**Guardrail #2:** the always-on `pensieved` service is the *primary* ingester, but
ingestion is not *exclusively* its job — the **app also drains the spool on
launch/foreground**. So the service is a correctness *convenience*, not a
correctness *dependency*: if it's down, capture still works (spool append is
independent of it) and the backlog drains next time the app opens. This is why the
service can be always-on without becoming the kind of fragile single-point-of-
failure the original sketch's network backend would have been.

## Intelligence (lazy, grounded, cited)

- Summaries are generated **on demand** — when I open a project or request the
  morning digest — **not per event**. Cheap, and never eagerly speculating.
- **Summary fields:**
  - **What It Is** — stable one-liner. Grounded, cheap.
  - **Last Work Done** — natural-language recap built directly from recent
    commits + session activity. The highest-value field; the grounded core.
  - **Blockers** — shown **only** when there's real signal (commit text, a stalled
    branch, an explicit checkpoint). Absent otherwise. Never invented.
  - **Loose Ends** — open items recovered from captured text, primarily Claude
    Code transcripts: stated-but-unfinished plans, TODO lists where only some
    items landed, ops steps discussed but not done (e.g. "set CI deploy vars
    before rollout"). **Every loose end cites its source** — a source event + a
    verbatim quote — e.g. *"session 2026-06-30: planned to add rate-limiting; no
    commit touches it since."* If it can't be grounded in captured text, it
    doesn't appear. This provenance rule is the entire defense against
    hallucination and is what makes the risky fields worth having.
- **"What's Next"** ranks on grounded signals only: days dormant, count of open
  loose ends, presence of an unfinished-looking branch. No invented risk scores.

### LLM provider abstraction

All model calls go through a single narrow `LLMProvider` protocol in
`PensieveKit` — roughly `send(prompt, model, responseSchema?) -> text/structured`.
Nothing else in the codebase knows which model or vendor is behind it.

- **Default provider: shell out to `claude -p`.** I have a Claude subscription, not
  an API key, so the default implementation invokes the Claude Code CLI in
  non-interactive print mode (`claude -p --model <model> [--output-format json]`,
  prompt on stdin). This uses my subscription auth — **no API key required**. It's
  heavier and slower than a raw API call (spawns a CC process, subject to
  subscription rate limits), which is fine for lazy, low-volume, personal use.
- **Alternate providers (not built now, not foreclosed):** an HTTP implementation
  of the same protocol can wrap the Anthropic, OpenAI, or Gemini APIs if I ever add
  a key. Swapping is a config change, not a code change elsewhere.
- **Model tiering** is expressed per provider: a cheap/fast model for per-item
  extraction (loose ends from a transcript), a stronger one for the daily
  synthesis. With the `claude -p` provider that's just the `--model` flag.

The abstraction is deliberately minimal — one protocol, one method — not a plugin
framework. It exists because provider-agnosticism is an explicit requirement, not
speculative flexibility.

## Persistence choice

**SQLiteData (pointfreeco/sqlite-data), which is built on GRDB.**

- GRDB underneath → real SQL for provenance/timeline joins, WAL for multi-process
  access (app + CLI share `pensieve.sqlite`), first-class migrations, a plain
  `.sqlite` file.
- Ergonomic `@Table`/`@FetchAll` value-type API → the native feel we want, closer
  to SwiftData but without SwiftData's multi-process weakness.
- **CloudKit sync is an opt-in `SyncEngine`** → the parked iOS companion becomes
  "flip it on later," not "build sync from scratch." We configure none of it now.
- Maturity caveat: SQLiteData is young (1.6.6 as of mid-2026). Acceptable —
  it's GRDB where it counts; worst case we drop to raw GRDB without a schema change.

**Boundary baked in from day one:** CloudKit sync, when it eventually exists, lives
**only in the entitled app process**. The CLI / git-hook capture path writes
locally and needs no iCloud entitlement. Hooks capture; the app syncs.

## Phasing

**Phase 1 — `PensieveKit` core + `pensieve` CLI.** Capture spool, ingester,
canonical store, git + transcript ingestion, the `LLMProvider` protocol with the
`claude -p` provider, loose-end extraction, grounded summaries, and CLI commands
(`capture*`, `next`, `status`, `group`, `checkpoint`, `digest`). Ingestion is
triggered synchronously via the CLI in this phase — no background service needed
to prove extraction quality.
→ *Verify:* real commits and sessions land as attributed events; `status <p>`
reads correctly; **loose ends are real and cited, with zero hallucinated items**
across a sample of my actual recent projects. This is the make-or-break gate.

**Phase 2 — `pensieved` always-on background service.** Promote ingestion to a
resident `SMAppService` agent: watch transcripts, drain the spool, generate
summaries and a morning digest in the background so state is fresh without me
doing anything. (App-side fallback draining still applies.)
→ *Verify:* committing / ending a CC session with no app open results, shortly
after, in updated canonical state and a ready digest.

**Phase 3 — `Pensieve.app`.** The three-pane native app on the proven core:
sidebar smart lists, project list, rich detail view with summary + timeline +
provenance. Live updates via GRDB observation.
→ *Verify:* opening the app shows correct current state for real projects; the
detail view's loose ends link back to their source events.

*(Phases 2 and 3 may be reordered during planning — the app self-drains the spool,
so it can ship before the standalone service if seeing the UI first matters more
than background-while-closed processing.)*

**Later — intended, not yet scheduled:** CloudKit sync, iOS companion, menu-bar
readout, widgets / Siri / Spotlight, additional source types, dependency graphs,
analytics. Build v1 so none of these are foreclosed.

## Key decisions & rationale (for future-me)

- **Swift throughout, app is the product.** The goal is a native macOS app (Mela-
  like), not a Python CLI with a Swift skin. One language, one framework, CLI and
  app are thin front-ends over `PensieveKit`.
- **Spool + canonical (two DBs), not direct-write, not daemon-broker.** The spool
  keeps capture dumb/fast/bulletproof and independent of any running process; the
  single-writer ingester keeps the canonical store clean and observable. This beats
  both a fragile "hook must reach a live daemon" design and a "hook writes the rich
  schema directly" design.
- **Read Claude Code transcripts directly.** They already contain plans, TODO
  lists, tool calls, and are keyed by project path on disk — far richer than the
  metadata a hook could POST. This is what makes grounded loose-ends possible.
- **Provenance-or-it-doesn't-exist.** The single rule that converts the scary
  AI fields from filler into the tool's most valuable output.
- **Provider-agnostic LLM layer, default `claude -p`.** No API key (subscription
  only), and a desire to swap in OpenAI/Gemini/etc. later → one narrow
  `LLMProvider` protocol, default implementation shells out to the Claude Code CLI
  using subscription auth.
- **Always-on `pensieved` service is first-class, but never on the capture
  critical path.** It makes the tool autonomous (fresh state + digest without
  opening the app) while the spool + app-fallback keep capture correct even when
  it's down. This is the distinction between "always-on background service" (wanted)
  and "network backend everything depends on" (the rejected original sketch).

## Risks / open concerns

- **Coupling to Claude Code's on-disk transcript format.** It is not a stable
  public contract and may change between CC versions. Mitigation: a defensive,
  well-isolated parser that fails soft (skip unparseable records, never crash
  ingestion) and is easy to update. Accepted risk — the data is too valuable to
  ignore.
- **Loose-end extraction quality is unproven.** This is exactly why Phase 1 gates
  on it before any UI investment.
- **SQLiteData maturity** — see persistence caveat above. Mitigated by the GRDB
  fallback path.
