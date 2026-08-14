# Transcript-passage chunking over BM25 — design

**Date:** 2026-08-14
**Status:** Approved in conversation 2026-08-14; ready for a plan.
**Supersedes:** `2026-07-19-transcript-passage-chunking-design.md`, which is kept unedited as the
record of the vector-era reasoning. That spec was approved and never planned; the engine it was
built on (`SemanticQueries`, `SemanticIndexer`, `TextEmbedder`, the KNN floor) was **deleted on
2026-08-11** after measuring worse than BM25. Only `EmbeddableCorpus` survived.
**Track:** C (findability) — the last open corpus increment.

## Why

The search corpus holds nodes, loose ends and enriched event summaries. All of those are *derived*
or *organized* artifacts. What it cannot recall is the raw conversation: the thing you actually said
while working a problem through, in the many cases where it never became a loose end and never made
it into a session summary.

Two goals, weighted equally — unchanged from the 2026-07-19 spec:

1. **Human recall in ⌥⌘F** — "I know I talked this through somewhere" resolves to the passage, not
   merely the project it happened in.
2. **Feeding Claude via MCP** — `search` finds the discussion, `recall` reads it back verbatim, so a
   fresh session reloads real prior reasoning instead of a summary of it.

What changed is not the goal. It is that the earlier design's central mechanism — *"the index stores
`content_hash`, **never text**… rendering a passage hit re-reads the transcript at query time"* — is
no longer viable, for a reason that was not visible in July.

## What was measured (2026-08-14, live store, read-only)

| Measurement | Value |
|---|---|
| `cc.session` events | **1,099** (805 when the July spec measured) |
| Unique `transcriptPath` values | 1,096 |
| Transcripts **still on disk** | **393 (36%)** |
| Missing | 703 |
| …of which a degenerate `~/.claude/projects/-` slug | **427** (see *Filed separately*) |
| Genuine work sessions | 669, of which **393 live (59%)** |
| Canonical store | 3.1 MB |
| Search index | 2.7 MB, **3,008 documents** |

Absence tracks age, so **the live transcript set is a rolling retention window, not an archive.**
July has both 279 present and 655 absent; something captured on 2026-08-13 is already gone.

**Approximate sizing** (30-transcript sample, extrapolated to 393): ~7.4k prompts and ~33k replies,
~31 MB of prose. **This is a jq measurement over raw JSONL, not a parser-faithful one**, and the
prompt figure is inflated because it does not apply `isInjectedOrCommand` — which is precisely what
drops the large injected bodies (skill bodies, `system-reminder` blocks, subagent results). It is
recorded as an order of magnitude and nothing more; §*Pre-registered gates* requires the real
measurement before implementation relies on it. This repo has a scar exactly here: two reviews of
the transcript-readability spec measured over raw JSONL instead of reproducing
`TranscriptParser.extractText`, and it invalidated that draft's evidence base.

## The three findings that reshaped the design

**1. A disposable index cannot be the system of record.** `SearchIndexStore` is declared disposable
and **whole-rebuilds from `EmbeddableCorpus.gather` whenever the corpus hash changes**. If passage
text lived only there, the first rebuild after a transcript aged out would delete that passage
permanently — a cache silently acting as the durable store. The July design was safe from this only
because it stored no text at all; that safety came at the cost of §3.

**2. Anchoring alone decays to the retention window.** Re-reading the transcript at query time means
recall is bounded by whatever Claude Code still has on disk — 59% today and falling. Pensieve exists
to reload context on months-old parallel efforts, so a feature whose memory is shorter than the
projects it describes does not serve the purpose.

**3. `documents` is contentful, so FTS5 wants the text anyway.** BM25 needs tokens. Storing text is
the grain of the engine rather than a concession to it.

## Decisions

| Decision | Reason |
|---|---|
| Passage text lives in the **canonical store**, new table, migration **v13** | Survives every index rebuild; `Ingester` stays the only canonical writer; the index stays a purely derived view. Precedent is exact — `LooseEnd.quote` is already a stored verbatim copy that is cited when the transcript is gone. On the `Pensieve` node, where in-node find measured it, only **18 of 122** open loose ends still had a live transcript, so the stored-copy path is already the normal case rather than the exception. (Measured on one node; the store-wide 36% transcript-survival figure above is the general shape.) |
| Corpus = **user prompts + adjacent assistant prose**, tool calls and results excluded | The July spec's "prompts only" was forced by embedding cost (*"~493k embeddings would cost hours"*), which no longer exists. Its stated reason for excluding replies — *"recall of Claude's side comes free via the surrounding window at resolution time"* — held only while the transcript was assumed present. For an aged-out session, prompts-only keeps the question and loses the answer, gutting goal 2. |
| Passages get their **own FTS5 table** | Measured, not stylistic: FTS5 normalises `bm25()` by a row's TOTAL token count, so mixing different-length content in one table regressed P@1 0.395 → 0.378 (McNemar p = 0.017, n = 1500) during P2′. Passages are far longer than a node name or commit subject. Same reason `document_files` is separate. |
| **One corpus hash per table** | Preserves whole-rebuild-per-table (no staleness bugs to reimplement) while keeping the common case cheap. See §*Rebuild cost*. |
| An unresolvable passage **degrades, never drops** | The inversion of the July spec's rule, whose justification (*"unlike a loose end, there is no stored quote to fall back on"*) no longer applies. |
| Surfaces: **MCP + one ⌥⌘F section**. No detail-pane section | The detail pane is about to be rewritten by design slice C and tested by the UI-verification harness; a third claim on `LooseEndRow`/`DetailView` would collide twice. |

## Architecture

### 1. `Passage` — canonical, migration v13

Additive, STRICT, UUID PK, written only by `Ingester`.

| Column | Purpose |
|---|---|
| `id` UUID PK | What the FTS index carries and the resolver re-reads. A real PK is why this design needs no composite `PassageRef` string — the July spec's `SemanticHit.id` problem disappears. |
| `nodeID` UUID | Attribution; supplies `state` to the corpus. |
| `eventID` UUID | Anchor to the `cc.session` event carrying `transcriptPath`. |
| `turnIndex` Int | Groups a prompt with the replies that followed it. |
| `messageIndex` Int | `TranscriptParser`'s own index, for the surrounding-window guard. |
| `role` | `prompt` / `reply`, as a `RawRepresentable` enum — not a bare string. This codebase converted `NodeKind`/`NodeState`/`LooseEndStatus` to enums specifically to kill mistyped-literal hazards. |
| `text` TEXT | **The durable record.** |
| `occurredAt` | Message timestamp, so a passage dates without joining its event. |

### 2. Extraction — no new filtering vocabulary

`TranscriptParser` already yields exactly what is needed:

- **Prompts** are `isUserPrompt` — conjunctive, and deliberately so (309 genuine `type:"user"`
  records in this repo's own transcripts contain envelope markers, because debugging this project
  means pasting envelopes into chat).
- **Replies** are `role == "assistant"`, which **already excludes tool calls for free**:
  `extractText` reads only `text` blocks, so a tool-use-only message yields empty text and never
  enters `messages`.
- **Tool results** arrive as `role: "user"` with `isUserPrompt == false`, excluded by the same gate.

**`TranscriptVocabulary.injectionMarkers` is read, never written or extended.** The FROZEN half of
that type exists so a tag added for display cannot silently change extraction; this feature adds no
tags at all.

Degenerate prompts ("ok", "go ahead") are dropped through the existing `TextQuality.isProse` gate.

### 3. Chunking, and what a hit is

Chunk sizes carry over from the July spec unchanged, because the reason survives the engine change:
a prompt at or under **2,000 characters** is one passage; longer text splits into **1,500-character
windows with 200 characters of overlap**, on a whitespace boundary where one exists. Overlap still
earns its place under BM25 — a phrase straddling a boundary matches neither side otherwise.

Overlap and long replies both mean **one turn can yield several documents**, which would put three
rows for one conversation in your results. Therefore:

- The index carries **one document per chunk** — chunks are what BM25 should score, since length
  normalisation is per document.
- The resolver maps chunk → **turn**, and `SearchQueries` **dedupes by turn, keeping the best
  score**. One conversation, one row, ranked by its best-matching chunk.

### 4. Producer and reconciliation

`EmbeddableCorpus.gather` grows a passage producer reading the **canonical table** — not transcripts.
This is the simplification the storage decision buys: the July design needed *"a sibling producer
with its own reconciliation path"* precisely because passages came from a different source than
everything else. They no longer do.

Pruning is membership-driven for free, exactly as it is for loose ends: the owning node supplies
`state`, `muted` is never indexed, and a deleted node takes its passages with it.

**The store's API surface stays explicit rather than kind-conditional.** Passages are gathered by
their own `gatherPassages` and written by their own `rebuildPassages(items:passagesHash:)`, and are
queried by their own `searchPassages(_:limit:includeArchived:)` returning its own hits — three
separate entry points, not a `kind == "passage"` branch threaded through `gather`, `rebuild` and
`search`. Two reasons, both load-bearing:

- The passage table rebuilds on its own hash (§5), so a single `rebuild` taking one mixed array
  would have to partition it and reconcile two hashes internally — the kind-conditional shape this
  codebase has already been burned by. `SearchIndexStore.statusFilter` carries the scar comment:
  *"a kind-conditional filter is exactly the asymmetry that lets the index and the canonical re-check
  drift apart."*
- Passage results are appended as their own section, never merged into the ranked list, so a caller
  that wants them asks for them. `search`'s exhaustive `switch` over `FTSQuery.shape` is left alone —
  passages are a different table, not a new query shape over `documents`.

### 5. Rebuild cost — one hash per table

`SearchIndexStore.rebuild`'s comment states *"FTS5 insertion is cheap (the whole corpus is
milliseconds), and a rebuild has no staleness bugs to reimplement."* That is true at 3,008
documents. At ~50k documents holding ~30 MB it is seconds — and it fires on **every** corpus-hash
change, so a single git commit would rebuild 50k passage documents that did not change, on every
300 s daemon run and every app refresh.

`meta` therefore grows `passages_hash` beside `corpus_hash`, and each table whole-rebuilds only when
its own hash moves. A commit rebuilds the 3k-document text table in milliseconds and leaves the
passage table alone; a newly ingested session does the reverse.

### 6. Ingest, and the retention race

`Ingester` already parses the transcript when enriching a `cc.session` event, so extraction hangs off
work it is already doing. Writes are **idempotent per event** — `TranscriptDiscovery` re-ingests
in-progress sessions as they grow, so it is delete-passages-for-this-event-then-rewrite, never
append.

A one-time backfill covers the 393 live transcripts. **This is the part with a clock on it.** Those
files age out continuously and each one lost is unrecoverable, so the implementation order is
store-and-backfill first, surfacing second: if the ⌥⌘F section slips nothing is lost, and if the
backfill slips, transcripts are.

### 7. Grounding and resolution

`SearchHit.Kind` gains `.passage`, which the resolver's exhaustive `switch` forces the implementer to
handle — the same compile-time no-drift guard the `DeepLink` work relied on.

1. Resolve passage → node → the shared `eligible()` allow-list, so `includeArchived` stays in
   lockstep with the SQL filter. *(Lockstep failure is an established bug class here — the
   archived-index work had to fix exactly this.)*
2. **Stored text is the snippet, always.** A hit is never dropped for a missing file.
3. The **surrounding window** is offered only when the transcript still exists *and* the stored text
   still occurs at `messageIndex` — the two-part `ProvenanceContext` guard, unchanged, which exists
   because compaction rewrites transcripts. Otherwise: the stored passage plus an accurate note, the
   honest-degrade path already shipped for loose ends.

**The trust gate is untouched.** This changes which real captured text is retrievable, never what may
be said about it. Passages are verbatim stored content, never generated, and never translated —
translation deliberately excludes captured content and provenance quotes.

## Surfaces

**⌥⌘F (global search):** a "From your conversations" section **below** the ranked list. Appended, not
interleaved — scores from a different table with a different average document length are not
comparable, exactly the reasoning `textWithPathProbe` already applies to path hits. Rows show the
matched snippet, node name and relative date; a disclosure expands the window in place using the
shipped inline-provenance treatment (cited chunk highlighted, machine-envelope messages dimmed).
Include Archived flows through unchanged since passages carry node state like every other kind. New
chrome strings are **hand-reconciled** into the String Catalog — `xcodebuild` does not extract them.

**MCP:** `search` gains passage items carrying the passage id as their handle plus the existing
`archived` flag. `recall` — today loose-end-keyed — accepts a passage id and returns the surrounding
window at model-controlled `radius`, the shape it already has.

## Testing

Kit-level, temp databases, synthetic transcript fixtures. The app target has no unit tests and gets a
build plus the usual non-blocking smoke of the inner binary. Note that the documented app smoke
recipe was reproduced during slice 5 to **exercise no app code at all**; the UI-verification harness
in flight is what will actually cover the ⌥⌘F section, and this spec should not claim coverage it
does not have.

- Chunker: short text → one passage; long text → overlapping windows with stable ordinals; the
  overlap genuinely overlaps; a whitespace boundary is preferred and a boundaryless string still
  splits.
- Extraction: `isUserPrompt` gates prompts; `role == "assistant"` yields replies; a tool-use-only
  assistant message produces nothing; a `tool_result` user record produces nothing; `isProse` drops
  "ok".
- Idempotence: re-ingesting a grown in-progress session replaces that event's passages rather than
  duplicating them.
- Turn dedupe: two chunks of one turn collapse to one hit at the better score.
- Producer: passages carry the owning node's `state`; a `muted` node contributes none; deleting a
  node removes its passages from the corpus.
- Per-table hash: a changed event rebuilds `documents` and **not** the passage table, and the reverse.
- Resolution: happy path; transcript missing → **hit still returned**, window withheld, note
  accurate; text changed under compaction → same; archived honoured only under `includeArchived`.
- A migration test pinning that v13 is additive and v4–v12 stores still open.

## Pre-registered gates

Two measurements decide whether this design survives contact, and both are to be taken before the
work they govern:

1. **A parser-faithful corpus measurement** — run `TranscriptParser` over the 393 live transcripts
   for real prompt/reply counts and bytes. Every size figure in this spec is explicitly approximate;
   if the true corpus is an order of magnitude off, §5 and the storage estimate both need revisiting.
2. **Rebuild wall-clock at real volume.** If a passage-table rebuild exceeds ~2 s, the per-table hash
   is not sufficient and incremental indexing gets specified rather than assumed.

**Relevance is explicitly unmeasured.** BM25's P@1 **0.395** was measured on a 3,008-document corpus
and does not describe a 50k-document one. The instrument that could measure it is **P3, the
paraphrase eval harness, which is blocked on the user writing a 30–50 query gold set**. This spec
does not claim passage relevance is known; it claims passages are *retrievable and grounded*. Anyone
tempted to cite 0.395 for the shipped system should read this paragraph first.

## Risks and limits

- **The corpus is bounded by what survives today.** 276 genuine sessions have already lost their
  transcripts and are unrecoverable. This feature cannot retrieve them; it stops the loss going
  forward.
- **~30 MB into the canonical store.** CloudKit is gated on a paid Apple Developer membership and so
  is not a live concern, but this is the store destined to sync, and the growth is real. UUID PKs are
  kept for that reason.
- **A long reply can outrank the prompt that prompted it.** Turn dedupe keeps one row, but which
  chunk wins is BM25's call.
- **Passage volume changes the ranked list's character** even in its own section, and see the
  relevance gate above.
- **Overlap stores text twice** in the index (not in canonical). Accepted for boundary recall.

## Out of scope

- **A detail-pane "Conversations" section.** Collides with design slice C and the UI harness.
- **Indexing tool output.** The bulk of the bytes and the least searchable content.
- **Retroactively recovering the 703 missing transcripts.** They are gone.
- **Archiving whole `.jsonl` transcripts** into a Pensieve-owned directory. Considered and rejected
  as scope: it is transcript retention with chunking as a view on top, and the passage table already
  captures the durable value. Not foreclosed.
- **Fixing the `claude -p` capture pollution.** Filed separately, below.
- **Any change to the trust gate, `injectionMarkers`, or extraction.**

## Filed separately — `claude -p` capture pollution

Found while measuring for this spec, and **not** part of this work:

**427 of the 1,099 `cc.session` events are Pensieve's own LLM calls.** All carry cwd `/` (project
slug `-`), **423 have exactly 1 prompt**, all are attributed to a junk node literally named `/`, and
their `workSummary` values are summaries *of other sessions* — one of which leaked the scaffolding
verbatim: *"The session is already summarized. Here it is in 1-2 sentences:"*. This is the `claude -p`
fallback provider firing the `SessionStart` hook, so Pensieve captured itself summarizing, then
summarized that.

**The bug is already fixed, twice, and cannot recur:** `ClaudeCLIProvider.shellRun` pins the child's
cwd to `PensievePaths.llmScratchDirectory()` — its comment describes this precise loop and the
"phantom project named `/`" it produced — and `Ingester.ingestSession` refuses
`ProjectResolver.isDegenerateRoot` as a second line of defense. All 427 events are dated 2026-07,
consistent with the fix, and the `/` node is archived.

What remains is **residue, not a defect**: those 427 summaries are in the BM25 corpus today under
Include Archived, and they inflate any count over `cc.session` events by 39% (the 36%-vs-59%
transcript-availability split above is exactly this). Purging them is a one-off maintenance question,
recorded in `backlog.md`. **This spec's passage corpus is unaffected either way** — those sessions have
no transcripts, so they can produce no passages.
