# Transcript-passage chunking — design

**Date:** 2026-07-19
**Status:** Approved (brainstormed with the user; ready for a plan)
**Track:** C (findability / OS-integration) — the last open item on that track.

## Why

The semantic index today holds nodes, open loose ends, and enriched event summaries. All of
those are *derived* or *organized* artifacts. What it cannot recall is the raw conversation:
the thing you actually said while working through a problem, in the many cases where it never
became a loose end and never made it into a session summary.

Two goals, weighted equally:

1. **Human recall in ⌘F** — "I know I talked this through somewhere" resolves to the actual
   passage, not just the project it happened in.
2. **Feeding Claude via MCP** — `search` finds the discussion, `recall` reads it back verbatim,
   so a fresh session reloads real prior reasoning instead of summaries.

## Sizing (measured, 2026-07-19)

- `~/.claude/projects`: 5,227 `.jsonl` sessions, 1.8 GB, ~493k lines.
- Canonical store: **805 `cc.session` events** — this, not 5,227, is the addressable universe,
  because a passage must anchor to a canonical event (see *Identity*).
- Estimated corpus: **~6,000–9,000 passages** after prompt-only filtering and chunk splitting.
- Index growth: 6.9 MB → roughly 40 MB. Acceptable for a rebuildable, never-synced store.

This sizing is what rules out indexing every message: ~493k embeddings on-device would cost
hours for content that is overwhelmingly tool output and machine envelopes.

## Scope

### In

- Index **user prompts only** — messages where `TranscriptParser` sets `isUserPrompt`, which
  already excludes tool results, injected skill bodies, slash-command envelopes, and
  `isMeta` records.
- **Chunk long prompts with overlap**; short prompts stay one passage. Concretely: a prompt at
  or under **2,000 characters** is one passage (matching today's `truncate` budget, a safe margin
  for the BERT-class token window); longer prompts split into **1,500-character windows with
  200 characters of overlap**, so a sentence straddling a boundary still matches from one side.
  Split on a whitespace boundary within the window where one exists, to avoid cutting mid-word.
- Filter degenerate prompts ("ok", "go ahead") through the existing `TextQuality.isProse` gate.
- Surface passages in **⌘F Related** (inline-expandable) and in **MCP `search` + `recall`**.

### Out (deliberately)

- Assistant prose and tool output. Recall of Claude's side comes free via the surrounding
  window at resolution time, without paying to embed it. Revisit if prompt-only recall proves
  insufficient in practice.
- Any new Settings toggle — the existing semantic-search toggle governs passages, including
  whether the backfill runs.
- Storing passage text in the semantic index (see *Grounding*).

## Identity

A passage anchors to the `cc.session` `Event` whose `detailJSON` carries `transcriptPath`
(the same field `ProvenanceQueries` already reads).

- `kind` = `"passage"`
- `itemID` = `"<event-uuid>#<messageIndex>#<chunkOrdinal>"`
- `nodeID` / `state` — inherited from the anchor event's node, exactly like `event` items

Anchoring buys node attribution, Focus/archive scoping, a canonical re-check target, and
prune semantics, all for free.

A small `PassageRef` value type owns format/parse in one place. Two query-layer changes follow,
because both are UUID-shaped today:

- `SemanticQueries.buildHits` does `UUID(uuidString: r.itemID)` → parse into an item ref that is
  a UUID for the three existing kinds and a composite for passages.
- `SemanticHit.id: UUID` → must carry the composite, or gain a separate stable `Identifiable`
  identity.

## Corpus production and reconciliation

`SemanticIndexer.sync` is **membership-driven** today: `EmbeddableCorpus.gather` returns the
complete live corpus and anything absent from it is pruned. That model does not fit passages,
in both directions:

- Re-parsing 805 transcripts every 300 s to re-derive an unchanged corpus is wasteful disk
  churn on the sync path.
- But a producer returning only *new* passages would make every previously-indexed passage look
  absent, and the prune step would delete them all.

So passages get a **sibling producer with its own reconciliation path**. `EmbeddableCorpus.gather`
is left exactly as it is. Two honest paths beat one producer contorted across two membership
models. *(Accepted for now; revisit if it becomes a maintenance painpoint.)*

- **Production is incremental.** The producer receives the anchor-event IDs already represented
  in the index and parses only transcripts for events not yet covered. Finished transcripts are
  immutable, so an indexed session is never re-read.
- **Pruning is canonical-driven.** A passage is stale iff its anchor event no longer exists or
  its owning node became ineligible (`muted`, deleted). A cheap canonical query — no transcript
  I/O.
- **Metadata upsert unchanged.** A repoint (strand materialization moving events between nodes)
  updates `node_id`/`state` by anchor event, without re-embedding.

### First-run backfill

~6–9k embeddings on-device is minutes, not seconds. It must be **interruptible and resumable**:
if the app quits or the background agent's 300 s window ends mid-backfill, the next sync resumes.
The indexer's existing property — items that fail to embed stay absent and are retried next
sync, never permanently starved — already provides most of this.

### Missing transcripts

Not an error. Old sessions are deleted or compacted. A missing file yields no passages; an
already-indexed passage whose file later vanishes degrades at resolution (below), matching the
posture of `ProvenanceContext.transcriptAvailable`.

## Grounding and resolution

The index stores `content_hash`, **never text**. It stays a rebuildable pointer index, not a
content store — a deliberate property of the current design that passages must not erode.

Therefore rendering a passage hit re-reads the transcript at query time.
`SemanticQueries.resolve(kind: "passage", …)`:

1. Fetch the anchor `Event`; fetch its `Node`; apply the same `eligible()` predicate as every
   other kind, so `includeArchived` stays in lockstep with the `knn` filter. *(This lockstep is
   an established bug class here — the archived-semantic-index work had to fix exactly this.)*
2. Read `transcriptPath` from `detailJSON`, parse, take the message at `messageIndex`.
3. **Verify the stored chunk still occurs in that message** — the two-part guard
   `ProvenanceContext` already uses, which exists because compaction rewrites transcripts and a
   stale index would otherwise highlight the wrong text.
4. Any step failing → **drop the hit**. Do not degrade.

Dropping rather than degrading is correct *here specifically*: unlike a loose end, there is no
stored quote to fall back on. A passage that cannot be re-read verbatim cannot be cited, and an
uncitable row does not belong in a grounded result set. **The trust gate is untouched** — this
changes which real captured text is retrievable, never what may be said about it.

Cost is bounded: resolution runs on at most `k` survivors, and transcript parses are memoized
per file within a single query so several hits in one session read it once.

## Surfaces

### App — ⌘F Related

Passage rows join the existing Related list: matched snippet, node name, relative date, a
distinguishing icon. A disclosure expands the surrounding transcript window in place, rendered
with the inline-provenance treatment already shipped for loose ends (cited chunk highlighted,
machine-envelope messages dimmed). Clicking the row header navigates to the owning node.

The Include Archived search scope flows through unchanged, since passages carry node state like
every other kind. New chrome strings get German entries **hand-reconciled** into the String
Catalog — `xcodebuild` does not extract them.

### MCP

- `search` gains passage items carrying the `PassageRef` string as their `id` handle, plus the
  existing `archived` flag.
- `recall` — today loose-end-keyed — extends to accept a passage ref and return the surrounding
  window at model-controlled `radius`, which is the shape it already has.

## Testing

Kit-level, temp DBs, synthetic transcript fixtures. The app target has no unit tests and gets a
build plus a non-blocking smoke-launch of the inner binary.

- `PassageRef` format/parse round-trip.
- Chunker: short prompt → one item; long prompt → overlapping windows with stable ordinals;
  boundary overlap genuinely overlaps.
- `isProse` gate drops "ok" / "go ahead".
- Producer: skips already-indexed anchors; missing transcript file → no items, no throw.
- Prune: anchor event deleted → passages pruned; node archived → `state` flips and passages
  **stay**; `muted` → pruned.
- Resolve: happy path; transcript missing → `nil`; text changed under compaction → `nil`;
  archived honored only under `includeArchived`.
- `SemanticQueries`: passage hits respect floor / visible / exclude, and the archived lockstep.

## Estimated scope

~6 tasks; +25–30 Kit tests. One Kit-heavy branch with a thin app slice.

## Open questions

None blocking. Deferred by choice: assistant-prose indexing; unifying the two producer paths.
