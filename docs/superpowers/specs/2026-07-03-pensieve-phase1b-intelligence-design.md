# Pensieve Phase 1B — Intelligence Layer — Design

**Date:** 2026-07-03
**Status:** Approved design (brainstormed with Moritz). Supersedes/refines the
Intelligence sections of `specs/2026-07-03-pensieve-mvp-design.md` and consumes the
design inputs in `phase-1a-outcome.md`. Next step: an implementation plan under
`plans/`.
**Audience:** Personal single-user tool (Moritz). Not a product.

## Why this phase exists

Phase 1A shipped capture → ingest → query with a **flat** `Project` model. Phase 1B
is the make-or-break gate: turn captured git + Claude Code activity into a **trustworthy,
grounded, provenance-cited** picture of where every parallel effort stands — loose ends,
summaries, and a "what's next" queue. If the loose ends aren't *real and cited with zero
hallucinations* on Moritz's actual projects, the project doesn't earn its UI.

Brainstorming reframed the data model substantially (below); the trust rule is unchanged
and absolute: **an AI-surfaced discrete claim must cite real captured text verbatim, or it
does not appear.**

## The conceptual reframe: a project is a node in a typed tree

The atom of Pensieve is a **mental context at any altitude**, not a repo or a branch.
Moritz works holistically ("Matchory Platform"), on concrete engagements ("Web
Application"), on targeted streams ("Service Principals for bots"), and on explorations
("does Stripe do credit billing") — and needs to see **where he forked mentally and left
something sitting**, at every altitude.

**Model: a recursive tree of typed nodes.** The flat `Project` becomes self-referential.

> **Naming decision for the plan (churn vs clarity).** Conceptually every row is a "node."
> Two options: (a) **rename `Project` → `Node`** (and `projectID` → `nodeID` across
> `Source`/`Event`/`LooseEnd`/`Checkpoint`, `ProjectResolver`, `ProjectQueries`, CLI, tests) —
> cleanest match to the model, but touches nearly everything 1A built; or (b) **keep the
> `Project`/`projects` name**, add the new columns, and accept that "project" now denotes any
> node kind. Recommendation: **(a) rename** — 1B is early (only 19 tests), the concept is
> foundational, and the confusion of a `domain`-kind row living in a `projects` table will
> outlast the one-time rename cost. To be confirmed at plan time.

The node gains:

- `parentID: UUID?` — nullable; a **strict tree** (acyclic by construction). Cross-cutting
  work (e.g. "client-credentials OAuth across the ecosystem") is *not* modelled as
  many-parents now; it lives as its own node and gains soft cross-references later via a
  link table (deferred — cycles are fine there since those are soft pointers, not parent
  edges).
- `kind: String` — an **open, soft label**, not an enforced level and not a closed enum.
  Seeded vocabulary: `domain`, `project`, `strand`, `concept`, `initiative`, `task`,
  `topic`. New kinds may appear over time with no migration. **No structural rule enforces
  which kind nests under which** — enforcement was explicitly rejected as the thing that
  chafes and gets abandoned.
- `name`, `description`, `state`, `createdAt` — first-class columns. `description` is
  generated (see strand birth) and user-editable.
- `metadataJSON: String` — a **free-form key-value bag**, mirroring the existing
  `Event.detailJSON` convention (chosen over an EAV table for YAGNI + consistency; SQLite
  `json_extract`/`->>` is available if query-by-key is ever needed). Holds strand
  birth-provenance (branch, worktree path, originating `sessionID`) and any other KV.

`group` (merge) is retained and keeps its existing invariant (repoint `looseEnds` /
`checkpoints` to the primary before delete).

## Attribution — two decoupled risk surfaces

The single most important architectural principle of 1B: **separate deterministic
attribution from fuzzy organization from the trust gate**, so we can be adventurous where
it's safe and strict where it matters.

1. **Project-altitude attribution is deterministic.** Path (repo root / transcript cwd) →
   node. No model in this path — an attribution *error* is as corrosive to trust as a
   hallucinated loose end, so the backbone stays deterministic.
2. **Strand placement + naming can be smart/fuzzy** — cheap-model naming, content
   inference, branch/worktree corroboration — *because* it is decoupled from surface 3. A
   mis-filed strand is a *legibility* bug (rename/reparent a node), not a *trust* bug.
3. **The loose-end truth gate is independent of strand placement.** A loose end must cite
   verbatim captured text to exist, full stop. If strand inference misfiles it, the item is
   still true and cited — it's just under the wrong node. Cheap to fix, non-corrosive.

**How strands come into being (Strategy B + content inference; LLM *classification*
deferred):**

- A commit/session on a **non-default branch** (or in a **worktree**) deterministically
  creates a `strand`-kind child under the project and attaches the event there. Work on the
  default branch attaches to the project node itself. The default branch deliberately
  creates *no* strand — only a divergence is a "fork."
- **A strand is born from doing work, not from git.** The primary birth signal is a Claude
  Code session (see below); git is the **timeline contributor** and a strong *corroborating*
  signal. A session is an *event* attributed to a strand — one session may span strands, one
  strand spans many sessions; session ≠ strand.
- The branch/worktree is only the *signal that births the strand and seeds its name*. The
  strand is then a first-class node — rename/retype/reparent freely; its identity isn't the
  branch. "Divorce from git" is preserved.
- **Domains grouping projects** stay a manual/LLM-assisted organizing step (low frequency),
  like `group` today.
- **Deferred out of 1B:** LLM classification of a session/commit into an existing strand
  purely from content (a second hallucination surface). We prove extraction first over a
  deterministic backbone.

## Strand birth & the session hook

At the moment work begins, we want the strand born already *described* from real text:

- A **lightweight session hook** appends a spool row referencing the transcript (optionally
  cheaply grabbing the first user message + session metadata into the payload so we keep it
  even if the file rotates). **The hook runs no LLM inline** — the capture path stays sacred
  (fast, fire-and-forget). All model work happens later in the ingester.
- The **ingester** reads the first user prompt + metadata and asks the local model for a
  human **strand name + description** grounded in that prompt (e.g. branch
  `feature/svc-principals` → "Service Principals for bot accounts"). Naming/description is
  *labeling*, not a *claim* — regenerable/editable, so it is **not** held to the strict
  verbatim gate (though it is derived from real content).
- **Open implementation detail (resolve against current docs in the plan):** at the literal
  `SessionStart` instant the first prompt may not exist yet; the reliable "first prompt"
  signal may be `UserPromptSubmit`. The exact Claude Code hook event is to be confirmed
  against **current Claude Code hook documentation** during implementation. Design intent is
  fixed: strand born early, described from the first real prompt + metadata.

## The loose-end pipeline (the gate)

**Enforcement — post-hoc verbatim verification.** The model proposes each candidate as
`{ text: the open item in Moritz's words, quote: verbatim span, sourceEventID }`. Before
anything persists, code verifies that `quote` appears **verbatim (whitespace-normalized) as
a substring of a single real captured message** in that event's transcript. Found → store.
Not found → **drop, silently.** Verbatim-within-one-message (not stitched across turns)
keeps verification unambiguous. The model extracts; code is the incorruptible gatekeeper.
This is the zero-hallucination guarantee — a property of the *system*, not the prompt, and
therefore **model-independent** (guided generation guarantees valid structure, not a
truthful quote).

**Extraction — per session, at ingest, stored.** When the ingester processes a session, it
runs cheap local-model extraction over the transcript (chunked into message-windows to fit
the on-device context limit), verifies each candidate, and writes surviving `LooseEnd` rows
(`sourceEventID` + `quote`). Loose ends are durable, cited facts in the table; summaries are
lazy synthesis over already-verified data — no re-extraction at query time. This matches
"single-writer ingester fills `looseEnds`."

**Resolution — conservative (surface, never auto-close).** Extraction defaults every item to
`open`. Loose ends are surfaced and *aged* ("open, untouched 24 days") but **never
auto-closed** in 1B. A wrong auto-close silently buries a real loose end — the exact betrayal
the tool exists to prevent. Auto-close (downgrading only on positive evidence of later work
referencing the item) is a deferred second-order feature, to be added once extraction itself
is trusted.

## The LLM layer — local-first, provider-agnostic

Verified available and **buildable on this machine** (macOS 26.5.1, Command Line Tools SDK
26.5 includes `FoundationModels.framework`; runtime framework present).

- **`LLMProvider` protocol** in `PensieveKit` — deliberately minimal (per MVP spec: "one
  protocol, one method", not a plugin framework), supporting structured output. Exact
  reconciliation of Foundation Models' `@Generable` guided generation with a uniform
  text/JSON interface is settled in the de-risking spike (below).
- **Default provider (BOTH tiers): on-device Apple Foundation Models** (`import
  FoundationModels`, `LanguageModelSession`, `@Generable`/`@Guide`). Free, local, private, no
  API key, no rate limits, no subprocess. Handles per-item extraction *and*
  summarization/synthesis. This refines the MVP spec's "model tiering = `--model` flag" into
  "tiering = different providers/configs behind one protocol."
- **Fallback only: `claude -p`** (`ClaudeCLIProvider`, subscription auth, no key). Used only
  when the on-device model is unavailable at runtime, or a task genuinely exceeds local
  capability (e.g. synthesis needing more context than the on-device window). If all goes
  well, 1B ships never invoking `claude -p` on this machine, while the abstraction keeps it —
  and any future HTTP provider — ready.
- **The plan MUST instruct the implementer to read current Apple Foundation Models / ML
  documentation** at implementation time (guided generation, summarization use-cases, the
  `SystemLanguageModel.default.availability` API, context limits) rather than rely on
  training memory — the framework is new and moving, and we want its full local surface.
- **Constraint: no Python, ever.** Foundation Models is Swift-native, so this is honored
  more cleanly than the subprocess default.

**First plan task is a de-risking spike:** confirm `SystemLanguageModel` availability on this
machine and a trivial `@Generable` extraction round-trip actually works, *before* the plan
commits to Foundation Models as default. If it fails, `claude -p` becomes the 1B default and
Foundation Models moves to a follow-up — the protocol makes this a config swap, not a
rewrite.

Caveats accepted: on-device model is small (~3B) and short-context (chunking required);
worst case is lower *recall* — the substring gate still protects *precision*, and weak
extractions can escalate to `claude -p`.

## Ingestion — source-agnostic, extensible

Dedup must not hard-code git/session assumptions (more source types are coming).

- **Source-agnostic idempotency fingerprint.** Every event carries a `fingerprint` string; a
  **unique `(sourceID, fingerprint)`** index + insert-or-ignore makes ingestion idempotent
  by construction. Re-drains after partial failure and concurrent `ingest` runs become
  no-ops.
- **The only source-specific bit is a per-kind fingerprint function:** git → the object hash;
  session → `sessionID + sha1(contents)`; future sources → whatever uniquely identifies
  their payload.
- **Per-kind ingestion handler.** Rather than a `switch` buried in the ingester, each kind
  supplies a small handler with three methods — `fingerprint(payload)`, `enrich(payload) →
  Event`, `extractLooseEnds(event) → [candidate]` — registered by kind string. The ingester
  core becomes generic: fingerprint → dedup → enrich → extract → store, with zero
  git/session knowledge. Adding a source later is "write a handler + register it." (This is
  requested flexibility, not speculative.)
- **Sessions ingested at end** (terminal transcript) → one snapshot → extracted once;
  re-running `ingest` on the same file is a clean no-op. The session hook is only a
  strand-birth *signal*, not a full ingestion, so there is no normal "grew since I ingested
  it" path. A rare mid-flight-then-end double produces two events attributing to the same
  node (no loose end lost) — accepted edge, no dedup complexity spent on it.
- **Loose-end idempotency falls out for free:** extraction only runs on genuinely-new events
  (identical content is a no-op upstream), so it can't pile up dupes.

## Output tier — three trust tiers

Each field is gated according to what it *is*:

- **Loose Ends & Blockers → strict verbatim gate.** Both are discrete claims; both cite real
  captured text or don't appear. Blockers shown *only* with real signal.
- **Narrative fields (What It Is, Last Work Done) → grounded narration, not verbatim-gated.**
  Facts are **assembled deterministically first** (recent commits, session activity, stored
  loose ends for the node); the model's job is strictly to *narrate the assembled inputs* and
  may not introduce a fact not in them. Provenance is *linkage* (built from these
  events/loose ends — clickable), not a verbatim quote. The model rewrites, never researches.
- **"What's Next" → fully deterministic ranking.** No model, no invented scores. Ranks on
  grounded signals only: days dormant, count of open loose ends, presence of a
  divergent/unfinished-looking strand. The model may at most *phrase* the one-line "why" from
  those same signals; it never computes the ranking.

**Scope:** node-level summaries (at the project/strand altitude where events attach) in 1B.
True recursive **domain-level rollup** is deferred; the first taste of rollup is the digest.

## CLI surface & addressing

New/enhanced commands (× essential to the gate, ○ makes the tree usable, △ spec deliverable):

- ×△ `status <node>` — **primary gate-inspection surface**: summary (What It Is / Last Work
  Done / Blockers) + every open loose end printed *with its verbatim quote and source event*.
- △ `next` — deterministic ranked queue across active nodes.
- △ `digest` — generated morning markdown (node summaries + top loose ends + what's-next) to
  stdout/file.
- × `checkpoint <node> "note"` — manual "I was mid-X" note.
- ○ `add-node --kind <kind> --name "…" [--parent …]` — manually create a **source-less node**
  (e.g. parking a `concept`/`topic` like the NLEmbedding spike).
- ○ `nest <child> <parent>`, `rename <node> <name>`, `retype <node> <kind>` — organize the
  tree.
- × `looseends [--all]` — flat citation listing to scan quickly across everything.
- (existing) `group`; `ingest` (now also extracts); hook install (now also the session hook).

**Addressing:** by `name`, but **when ambiguous, print candidates** with their `kind` +
parent/path + short id and exit asking to disambiguate; also accept `--id <uuid-prefix>` for
scripts. (Tree worsens name collisions; the 1A outcome flagged preferring ID-based
addressing.)

## Validation gate (the acceptance run)

The whole point of 1B before any UI. Install hooks on a handful of Moritz's real repos (or
point `ingest` at existing `~/.claude/projects/**` transcripts), run `ingest`, then `status`
each real project and read loose ends against their quotes; `looseends --all` for a fast
sweep. **Pass = every loose end is real and verbatim-cited, with zero hallucinated items.**
Only then does UI work (Phase 3) begin.

## Deferred (on the roadmap, not foreclosed)

- **NLEmbedding statistical theme discovery** — see `backlog.md`. Native (`NaturalLanguage`,
  no Python); revisit once the grounded layer is proven; keep it citable (embeddings as a
  retrieval aid feeding grounded LLM synthesis, not raw clusters).
- **LLM strand classification** from content (beyond deterministic branch/worktree +
  birth-time naming).
- **Loose-end auto-close** (evidence-based resolution).
- **Domain-level recursive rollup** summaries.
- **Cross-cutting soft references** (a `node_links` table; DAG-ish, cycles allowed).
- Everything already deferred in the MVP spec (`pensieved` service, the app, CloudKit, etc.).

## Key decisions & rationale (for future-me)

- **Typed recursive tree, soft labels, no enforced levels.** Matches how Moritz actually
  works (altitude varies); enforcement was rejected because reality won't cooperate and rigid
  levels get abandoned. `kind` open-string so new categories cost nothing.
- **Decouple attribution / organization / trust.** Deterministic project attribution + an
  independent verbatim gate let strand inference be fuzzy without endangering trustworthiness.
- **Provenance-or-it-doesn't-exist, enforced in code.** Post-hoc substring verification makes
  the guarantee a system property, independent of which model runs.
- **Local-first LLM (Apple Foundation Models), `claude -p` as pure fallback.** No key, no
  rate limits, private, Swift-native (honors no-Python best). Provider-agnostic protocol
  keeps everything swappable.
- **Source-agnostic fingerprint + per-kind handler.** The ingester learns nothing about git
  or Claude Code; new sources slot in as handlers.
- **Conservative resolution.** Never silently bury a real loose end — the failure mode the
  tool exists to prevent.

## Risks / open concerns

- **On-device extraction quality is unproven** — gated by the first-task spike and, ongoing,
  by the acceptance run. Precision protected by the substring gate regardless; recall is the
  variable to watch.
- **Claude Code transcript & hook formats are not stable contracts** — defensive parsing
  (already in 1A) and confirming the hook event against current docs mitigate; accepted risk.
- **Foundation Models context limit** forces transcript chunking; extraction is naturally
  chunkable, so low risk, but long single messages could still truncate — note in the plan.
