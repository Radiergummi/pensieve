# Pensieve Phase 1B — Intelligence Layer (the gate) — Design

**Date:** 2026-07-03 (rev. 2, after adversarial review)
**Status:** Approved design (brainstormed with Moritz; revised after a two-agent
adversarial review). Refines the Intelligence sections of
`specs/2026-07-03-pensieve-mvp-design.md` and consumes `phase-1a-outcome.md`. Next step:
an implementation plan under `plans/`.
**Audience:** Personal single-user tool (Moritz). Not a product.

## Scope decision (read first)

An adversarial review found that the richer conceptual model we brainstormed (a recursive
typed tree of nodes, automatic strand birth, a session hook, a `Project→Node` rename, a
per-kind ingestion-handler abstraction, and organizing CLI) is **off the critical path of
the make-or-break gate** and, by the design's own decoupling argument, is the cheap,
deferrable *organization* layer. It also depends on capture-time signals 1A does not yet
record (worktree identity, default branch) and would be far better designed against real
data. So **Phase 1B is descoped to the gate itself.**

- **1B (this spec) — THE GATE.** On the existing **flat `Project` model**, prove that
  extracted loose ends are *real and verbatim-cited, with zero hallucinated items* on
  Moritz's actual recent projects. Nothing more.
- **1B-org (deferred, own spec later).** The typed tree, strands, session hook, naming,
  `Node` rename, ingestion-handler abstraction, and organizing CLI — written **after** the
  gate passes, informed by the real captured data. Deferring is a cheap additive migration
  later; it forecloses nothing (UUID PKs + STRICT keep CloudKit reachable regardless). The
  full deferred list and rationale live at the end + in `backlog.md`.

The trust rule is unchanged and absolute: **an AI-surfaced discrete claim must cite real
captured text verbatim, or it does not appear.**

## What 1B builds

1. An `LLMProvider` protocol, default = **on-device Apple Foundation Models**, fallback =
   `claude -p`.
2. **Loose-end extraction** from Claude Code transcripts → verified, cited `LooseEnd` rows.
3. A **post-hoc verbatim verifier** — the incorruptible gatekeeper.
4. **Source-agnostic event dedup** (the 1A-outcome carry-forward), so re-runs don't
   duplicate events or loose ends.
5. **Grounded summaries** (three trust tiers) and a **deterministic "what's next."**
6. CLI: enhanced `status`, `looseends`, `next`, `checkpoint`, thin `digest`.
7. A **validation gate** procedure that measures precision *and* recall.

Everything runs against the flat model 1A shipped: `Project`, `Source`, `Event`,
`LooseEnd`, `Checkpoint` (UUID PKs, STRICT). Only additive schema changes (below).

## Data model changes (additive only)

- **`Event.fingerprint: String`** + a **unique index `(sourceID, fingerprint)`** — the
  source-agnostic idempotency key (see Ingestion). Migration `v3`; **backfill existing rows**
  (commit → hash, session → sessionID; see checkout note) and make the column nullable or
  backfilled so the migration succeeds over already-captured data. Migration test required.
- **`LooseEnd` gains `role: String` and `sourceMessageIndex: Int`** (in addition to the
  existing `sourceEventID`, `text`, `quote`, `status`). These record *which message* (and its
  role) the quote came from — needed to enforce the role rule, to dedup by source span, and
  to audit provenance. (`text` = the open item in Moritz's words; `quote` = the verbatim
  span; both retained.)

No tree columns, no rename in 1B.

## Transcript corpus & parser (the substring gate depends on this)

The verifier matches a candidate `quote` against **exactly the strings the extractor was
shown**, so the corpus must be pinned:

- **Extend `TranscriptParser`** to (a) distinguish a *genuine user prompt* from Claude
  Code's `type:"user"` **tool-result** records (which the current `userPromptCount` wrongly
  counts) and from injected/meta content, and (b) optionally expose **TodoWrite / tool
  content**, since the MVP's canonical loose-end examples ("TODO lists where only some items
  landed") live there. Keep it defensive (skip unparseable records; never crash ingestion).
- Extraction and verification run **in the same ingest pass over the freshly-parsed
  messages**, so the corpus is exactly what was parsed (the transcript file exists during the
  run). Storing `quote` + `role` + `sourceMessageIndex` makes the citation displayable and
  auditable afterward; a durable text snapshot (surviving transcript rotation) is a
  nice-to-have, deferred.

## The loose-end pipeline (the gate)

**1. Extract (local model, chunked).** Over a session's parsed messages, chunked into
windows that fit the on-device context limit, the model proposes candidates
`{ text, quote, sourceMessageIndex }`. Extraction targets: stated-but-unfinished plans,
partial TODO lists, ops steps discussed but not done — **from genuine user-authored prose
only** (see verifier rule 2).

**2. Verify (code — the incorruptible gate).** A candidate is stored only if ALL hold;
otherwise it is **dropped** (and counted — see instrumentation):
  1. `quote` appears **verbatim (whitespace-normalized) as a contiguous substring within a
     single stored message** (no cross-message and no cross-content-block stitching — the
     parser joins blocks with `\n`; the match must sit inside one block).
  2. that message is **genuine user-authored prose** — *not* an assistant message, *not* a
     tool-result record, *not* pasted/quoted external text where detectable. (This is why
     `role`/`sourceMessageIndex` are recorded.) Quoting Claude's own suggestions or a pasted
     Slack message as "Moritz's loose end" is the failure this rule prevents.
  3. `quote` meets a **minimum length** (token/char floor) so trivial matches ("TODO") can't
     satisfy the gate.

**3. Dedup (so the never-close list stays signal, not noise).**
  - **Within session / across chunks:** collapse candidates with the same
    `(sourceEventID, normalized-quote)` or overlapping source span — chunking must not
    produce duplicate rows.
  - **Across sessions:** a restatement of the same unfinished thing in a later session
    **supersedes/collapses** rather than adding a parallel open item. (This is *collapse*,
    distinct from auto-close, which stays deferred — but without it the monotonic
    never-closing list decays into noise, and usefulness == trust.)

**4. Resolve — conservative.** Everything defaults to `open`; loose ends are surfaced and
**aged**, never auto-closed in 1B. **Aging is computed from the source `Event.occurredAt`
(joined via `sourceEventID`), not `LooseEnd.createdAt`** — ingesting an old transcript today
must not make weeks-old work look fresh. Evidence-based auto-close is deferred.

**Display rule (critical): lead with the quote.** In every surface, the **verbatim quote is
the primary, authoritative line**; the model's `text` paraphrase is clearly secondary/derived.
The guarantee is "you are reading real captured text" — so the human reads the quote. This
also neutralizes the "real quote, distorted paraphrase" attack: even a bad `text` sits next
to the true words it derives from.

## The LLM layer — local-first, provider-agnostic

Verified available and **buildable on this machine** (macOS 26.5.1; CLT SDK 26.5 ships
`FoundationModels.framework`; runtime framework present).

- **`LLMProvider` protocol** in `PensieveKit` — deliberately minimal (per MVP: "one protocol,
  one method"), supporting structured output. Reconciling Foundation Models' `@Generable`
  guided generation with a uniform text/JSON interface is settled in the spike below.
- **Default: on-device Apple Foundation Models** (`import FoundationModels`,
  `LanguageModelSession`, `@Generable`/`@Guide`). Free, local, private, no API key, no rate
  limits, no subprocess — ideal for high-volume per-session extraction. **Local-first from the
  start** (Moritz's decision) for extraction *and* summarization.
- **Fallback: `claude -p`** (`ClaudeCLIProvider`, subscription auth, no key) — used when the
  on-device model is unavailable at runtime, when a task exceeds local capability, **and to
  escalate individual weak/low-recall extractions** (the safety valve that keeps local-first
  viable). Guided generation guarantees valid *structure*, not a truthful quote, so **the
  substring gate stays and is model-independent.**
- **The plan MUST instruct the implementer to read current Apple Foundation Models / ML
  documentation** at implementation time (guided generation, summarization use-cases,
  `SystemLanguageModel.default.availability`, context limits) — the framework is new and
  moving; use its full local surface.
- **No Python, ever** — Foundation Models is Swift-native, honoring this cleanly.

**First plan task is a de-risking spike:** confirm `SystemLanguageModel` availability and a
trivial `@Generable` extraction round-trip on this machine *before* the plan commits. If it
fails, `claude -p` becomes the default (a config swap, not a rewrite).

## Ingestion — source-agnostic dedup

The 1A-outcome carry-forward, kept minimal for the gate:

- **Source-agnostic fingerprint.** Each event carries a `fingerprint`; the unique
  `(sourceID, fingerprint)` index + **insert-or-ignore** makes ingestion idempotent
  (re-drains, concurrent `ingest`). `sourceID` is stable per `(key, kind)` in
  `ProjectResolver`, so the key is stable.
- **The only source-specific bit is a per-kind fingerprint function** (isolated in one
  place): commit → object hash; **checkout → a synthetic key** (it has no natural immutable
  id — define one, e.g. `sha1(repo|from|to|branch|ts)`, accepting that identical toggles may
  collapse); session → `sessionID + sha1(contents)`. *(A full per-kind handler protocol is
  deferred to 1B-org / when a 4th source arrives — a `switch` over three kinds is the
  YAGNI-correct amount of structure now.)*
- **Extraction runs only when the insert actually happened** (check rows-affected on
  insert-or-ignore) — so re-drains and the rare mid-flight-then-end session double don't
  re-extract and duplicate loose ends.
- **Sessions ingested at terminal state** (SessionEnd / CLI), once. No mid-flight ingestion
  in 1B, so the "growing file" case doesn't arise on the normal path.

## Output tier — three trust tiers

- **Loose Ends & Blockers → strict verbatim gate** (above). Blockers shown *only* with real
  signal; each cites captured text or doesn't appear.
- **Narrative fields (What It Is, Last Work Done) → grounded narration, fenced.** Facts are
  **assembled deterministically first** (recent commits, session activity, stored loose ends
  for the project); the model only *narrates the assembled inputs* and may not introduce a
  fact not in them. Because that constraint isn't code-enforced, generated prose is **visually
  fenced** from verbatim-cited items in every surface, so it can't borrow the gate's
  credibility. (Prefer deterministic templated assembly where it reads acceptably.)
- **"What's Next" → fully deterministic ranking.** No model, no invented scores. Ranks on
  grounded signals: days dormant (from `Event.occurredAt`), count of open loose ends,
  presence of an unfinished-looking branch. The model may at most *phrase* the one-line "why";
  it never computes the ranking.

Summaries are at the project level (flat model — no rollup question in 1B).

## CLI surface & addressing

- **`status <project>`** — primary gate-inspection surface: the (fenced) summary + every open
  loose end printed **quote-first**, with role + source event; aged.
- **`looseends [--all]`** — flat citation listing (quote-first) to sweep across everything
  fast.
- **`next`** — deterministic ranked queue across active projects.
- **`checkpoint <project> "note"`** — manual "I was mid-X" note.
- **`digest`** — thin generated morning markdown (project summaries + top loose ends +
  what's-next). Rides on validated loose ends; secondary to the gate.
- (existing) `group`, `ingest` (now also extracts), hooks. Addressing: by `name`; on ambiguity
  print candidates (kind/path/short-id) and exit; accept `--id <uuid-prefix>`.

## Validation gate (the acceptance run) — precision AND recall

The whole point of 1B before any UI.

1. Point `ingest` at existing `~/.claude/projects/**` transcripts (and/or install hooks on a
   handful of real repos), run `ingest`.
2. **Precision:** `status`/`looseends --all` — read each loose end against its quote. **Every
   one must be real and verbatim-cited; zero hallucinated or misattributed items.**
3. **Recall spot-check:** for ≥1 real session, hand-label the loose ends you know are there;
   require the pipeline surfaces them (a degenerate extractor that drops everything must NOT
   pass).
4. **Instrumentation:** the pipeline logs **proposed / verified / dropped** counts per session,
   so "nothing to find" is distinguishable from "extractor broken" — and so a thin local-model
   recall shows up as droppable-to-`claude -p`, not as a false gate failure.

Pass on precision + a credible recall spot-check → Phase 1B-org (the tree/strands), then UI.

## Deferred → 1B-org and beyond (on the roadmap, not foreclosed)

Written as its own spec after the gate passes, designed against real data:

- **Typed recursive tree** (`parentID`, open-string `kind`, `description`, `metadataJSON`) and
  the **`Project→Node` rename**.
- **Strand birth** — needs new capture-time signals (worktree identity via
  `git rev-parse --git-common-dir`, default-branch resolution, detached-HEAD handling) that 1A
  doesn't record; must not explode strands on short-lived/merged branches, and must collapse
  "worktree + branch for the same fork" to one strand. Best designed against observed data.
- **Session-start hook + cheap-model strand naming/description.**
- **Per-kind ingestion-handler protocol** (when source #4 arrives).
- **Domain-level recursive rollup** summaries.
- **Evidence-based loose-end auto-close.**
- **Cross-cutting soft references** (`node_links`; cycles allowed — soft pointers, not parent
  edges).
- **NLEmbedding statistical theme discovery** — see `backlog.md`.
- Everything already deferred in the MVP spec (`pensieved`, the app, CloudKit, iOS, …).

## Key decisions & rationale (for future-me)

- **Gate-first, flat model.** The phase exists to answer one risky question cheaply; the
  organization layer is deferrable by the design's own decoupling argument and forecloses
  nothing (additive migration later). Front-loading the tree inverted the priorities.
- **Provenance-or-it-doesn't-exist, enforced in code, quote-led in display.** Post-hoc
  substring verification is a *system* property, model-independent; leading with the quote
  defeats the "real quote, distorted paraphrase" attack.
- **Role/provenance-constrained extraction.** Only genuine user prose counts — not the
  assistant's suggestions or pasted text.
- **Precision *and* recall in the gate.** A precision-only gate is passed by a broken
  extractor; instrumentation keeps the local-first signal interpretable.
- **Dedup + collapse, conservative resolve.** Never bury a real loose end (no auto-close);
  never let restatements decay the list into noise (collapse).
- **Local-first LLM, `claude -p` as fallback + escalation valve.** No key, private,
  Swift-native (honors no-Python); provider-agnostic protocol keeps everything swappable.
- **Source-agnostic fingerprint via a function + `switch`.** Isolates source-specifics
  without the premature handler-protocol framework.

## Risks / open concerns

- **On-device extraction recall is unproven** — gated by the spike and the recall spot-check;
  precision is protected by the substring gate regardless; the `claude -p` escalation valve is
  the mitigation. This is the variable to watch.
- **Claude Code transcript & tool-record formats are not stable contracts** — defensive
  parsing (extended in 1B) mitigates; accepted risk.
- **Foundation Models context limit** forces chunking; extraction is naturally chunkable, but
  a single very long message could truncate — note in the plan.
- **Checkout fingerprint** has no natural id; the synthetic key may collapse identical toggles
  — acceptable for the gate (checkouts aren't a loose-end source), revisit in 1B-org.
