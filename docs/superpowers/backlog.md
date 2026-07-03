# Pensieve — Backlog (deferred, not forgotten)

Ideas we've deliberately parked so a phase stays focused. Each is on the roadmap;
none is foreclosed. Revisit when the noted trigger arrives.

---

## Phase 1B-org: the typed tree & strands (deferred out of the 1B gate)

**Parked:** 2026-07-03, after an adversarial review of the 1B spec.
**Revisit when:** the 1B gate passes (loose ends real + verbatim-cited, zero hallucinations
on real projects) — then write a `1B-org` spec designed against the real captured data.

The conceptual model we brainstormed (see the rev-1 discussion) is intentionally deferred so
1B reaches its make-or-break gate cheaply. It forecloses nothing (additive migration; UUID
PKs + STRICT keep CloudKit reachable). Carry forward:

- **Typed recursive tree of nodes** — `parentID` (strict tree), open-string `kind`
  (`domain`/`project`/`strand`/`concept`/`initiative`/`task`/`topic`, soft labels, no enforced
  levels), `description`, `metadataJSON` bag. The **`Project→Node` rename** goes here too.
- **Strand birth needs new capture-time signals 1A doesn't record** — worktree identity
  (resolve via `git rev-parse --git-common-dir`, *not* `--show-toplevel`, which sends a
  worktree to a separate project), default-branch resolution (`origin/HEAD` → config →
  fallback), detached-HEAD handling (don't mint a "HEAD" strand). Must avoid strand explosion
  on short-lived/merged branches and collapse "worktree + branch for one fork" to a single
  strand. If `metadataJSON` holds the strand's branch key, note it's queried-by-key on the
  ingest hot path → promote that key to a real column (the YAGNI-blob argument fails here).
- **Session-start hook + cheap-model strand naming/description** (confirm the exact Claude
  Code hook event — `SessionStart` may fire before the first prompt exists; `UserPromptSubmit`
  may be the real signal — against current CC docs).
- **`group()` must also repoint children's `parentID`** once the tree exists (extend the
  existing invariant + `groupPreservesLooseEndsAndCheckpoints` test).
- **Per-kind ingestion-handler protocol** (fingerprint/enrich/extract) — introduce when a 4th
  source type actually arrives; a `switch` suffices for git+session.
- **Domain-level recursive rollup** summaries (CTE over descendants) so `status <domain>`
  shows loose ends sitting in child strands.
- **Organizing CLI:** `add-node`, `nest`, `rename`, `retype`.
- **Cross-cutting soft references** (`node_links`, cycles allowed).
- **Evidence-based loose-end auto-close** (1B only surfaces + ages; never auto-closes).

---

## Spike: statistical theme discovery across strands (`NLEmbedding`)

**Parked:** 2026-07-03, during Phase 1B brainstorming.
**Revisit when:** the grounded loose-end/summary layer (1B) is proven and we want the
"broad picture of how strands unfold across the whole tree" — i.e. surfacing
*recurring cross-cutting themes* ("you keep touching auth across three projects")
rather than per-project state.

**Idea:** use unsupervised statistical analysis (word2vec-style embeddings +
clustering) over captured session/commit text and extracted loose ends to surface
recurring themes and candidate cross-cutting strands/concepts automatically.

**Constraints & the native path:**
- **No Python, ever.** The Swift-native route is Apple's `NLEmbedding` (the
  `NaturalLanguage` framework) for on-device word/sentence embeddings — no API key,
  no external service, runs locally. This is the intended implementation surface.
- **Grounding caveat (important).** Opaque embedding clusters are hard to *cite*,
  which cuts against Pensieve's provenance-or-it-doesn't-exist north star. When we
  build this, prefer using embeddings as a *retrieval/grouping aid* that feeds a
  grounded LLM synthesis (which can cite real captured text), rather than surfacing
  raw clusters as if they were findings. Themes must still trace to captured text.

**Why it's a perfect Pensieve dogfood case:** this note is itself a `concept`/`topic`
— a targeted exploration parked for later. When Pensieve can track a strand like this
(let me forget it for a month, then reload full context and continue), it's working.
