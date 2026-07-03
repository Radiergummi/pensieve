# Pensieve — Backlog (deferred, not forgotten)

Ideas we've deliberately parked so a phase stays focused. Each is on the roadmap;
none is foreclosed. Revisit when the noted trigger arrives.

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
