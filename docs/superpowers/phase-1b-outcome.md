# Phase 1B — Outcome & Precision Handoff

**Date:** 2026-07-03. **Status:** the intelligence-layer machinery is built, reviewed, and green (**55 tests**) on branch `phase-1b-intelligence` — **not merged**. The make-or-break **precision gate is now PASSED** (see "Precision gate — RESOLVED" below); the sections after it are the historical diagnosis that led there. Read this before continuing 1B.

## Precision gate — RESOLVED (2026-07-03, same day)

The precision work below was executed and the gate now passes. **Three final on-device acceptance
runs over the same three real transcripts: 7 / 10 / 8 loose ends, ZERO noise and ZERO fabrication in
every run** (was 39 with ~25 noise). Counts are stable run-to-run and `verified ≈ proposed` — the
extractor now sees clean genuine prose. Recall intact (genuine items surface, incl. *"give me a
prompt to hand to the new agent"*, *"review the entire unpushed diff for convention violations"*, the
swarm-spec/compose concern, the YAML-tags thread, a full run of real code-review questions).

**What fixed it (three levers, in commit order):**
1. **Guided generation** for the on-device provider — `FoundationModelsProvider` now returns
   structured output via a **runtime-built `GenerationSchema`** (`DynamicGenerationSchema` +
   `GeneratedContent.kind`), *not* the `@Generable` macro. The macro compiles under `swift build`
   but its plugin fails to load in this CLT-only machine's **test build**; the runtime API needs no
   macro, so `test.sh` compiles. Structured methods (`extractCandidates`/`classifyGenuineIndices`)
   sit on `LLMProvider` with text-based defaults, so `claude -p` and all test mocks are unchanged.
   This ended the "3B won't emit JSON → classifier fails open → no-ops" root cause; the classifier
   now trusts a structured empty result as *drop* (fail-toward-drop), fail-open only on a throw.
2. **`isMeta == true` structural gate in `TranscriptParser`** — Claude Code's own flag for injected
   content it records as `type:"user"` (slash-command bodies like `/simplify`/`/code-review`, **skill
   bodies**, caveats). This was the dominant remaining noise: the extractor was chunking giant
   injected skill/command bodies and mining their embedded checklists/rubrics as fake loose ends,
   which also caused wild run-to-run instability (7 vs 91 proposed). `isMeta` is robust and universal;
   verified across all three transcripts that it flags only injected content, never genuine prose.
3. **Inline-tag markers** (backstop for injected content `isMeta` doesn't flag): added
   `<task-notification>`, `</tool_uses>`, `<subagent`, `[Request interrupted`, `Base directory for
   this skill:` to the existing command/injection marker list.

**Dead end (recorded so no one retries it):** tightening the *classifier prompt* with explicit
"a rubric/checklist line is not intent" examples **backfired** — the 3B model is too weak/unstable to
filter this semantically (the exact examples still leaked, and one run exploded to 91 proposed). The
leaks were structural injections; the parser (`isMeta`) is the right layer. The classifier prompt was
reverted to its committed form.

**Verdict: precision gate PASSED; recall spot-check credible; trust guarantee intact.** Next per the
spec is Phase 1B-org (the typed tree / strands), designed against this now-clean real data — plus the
deferred minor findings below.

---

*(Historical: the diagnosis that produced the plan above.)*

## What Phase 1B shipped (branch `phase-1b-intelligence`, 20+ commits)

Built gate-first on the flat `Project` model (the tree/strands were deliberately deferred — see `backlog.md`). Every task passed per-task spec+quality review; a final whole-branch review (on Sonnet — Opus was over the org monthly spend limit) found 1 Critical + 2 Important, all fixed and re-approved.

- **`LLMProvider`** (`Sources/PensieveKit/LLM/`): local-first. Default = on-device **Apple Foundation Models** (confirmed available + buildable on this machine, macOS 26.5.1); fallback = `claude -p` (its shell had two real pipe-deadlock bugs, both caught in review and fixed). Selection is factored so `defaultProviderKind()` and `makeDefaultLLMProvider()` can't diverge.
- **The trust gate** — `LooseEndVerifier` (`Intelligence/`): a loose end is stored only if its `quote` is verbatim-present (whitespace-normalized, min-length on the *normalized* quote) in a **genuine user-authored** message. Pure code, model-independent. All 5 hallucination vectors are pinned by mutation-resistant tests.
- **Extraction** — `LooseEndExtractor` (user-prose chunking; adaptive **re-split on context-overflow** so token density can't fail a session) → `IntentClassifier` (on-device pre-filter, fail-open) → `LooseEndVerifier` → `ExtractionRunner` (dedup/collapse by normalized quote, per-session `extractedAt`, per-session **error isolation**, proposed/verified/inserted counts).
- **Ingestion**: source-agnostic **fingerprint dedup** (`insertIfNew` on `(sourceID, fingerprint)`, single-writer safe + unique-index backstop). Additive **v3 migration** (backfill + unique index + pre-existing-dup collapse guard). Runtime & backfill fingerprint formats aligned to `commit:<hash>` / `session:<sessionID>`.
- **Parser** (`Transcript/`): messages carry `index` + `isUserPrompt` (excludes assistant, tool-results, and — added during the acceptance run — injected/command-marker content: `<command-*>`, `<local-command-stdout>`, `<system-reminder>`, the "Caveat:" prefix).
- **CLI**: async `ingest` (drain+extract, prints counts), quote-led `status`, `looseends [--all]`, deterministic `next`, `checkpoint`, fenced `digest`.

## The acceptance run (Task 14) — three passes on real transcripts

Ingested Moritz's real `~/.claude` transcripts from three realms (matchory-litellm, matchory-webapp, docker-swarm-deployment-action) into throwaway stores; extraction ran **on-device (free, private)**.

| Pass | Change | proposed→verified→inserted | Sessions failed | Precision read |
|---|---|---|---|---|
| 1 | baseline | 9 → 7 → 6 | 1 (context limit) | ~3 genuine, rest brief-noise + 1 distortion |
| 2 | chunk-split + marker filter | 20 → 11 → 11 | 1 (token-density edge, 4090/4096) | more genuine, but brief/subagent-result noise ↑, 1 garbage XML fragment |
| 3 | intent classifier + adaptive re-split | 84 → 40 → **39** | **0** | ~12–14 genuine (excellent), ~25 noise |

## Verdict

- ✅ **Trust guarantee holds.** Zero fabricated quotes across all passes; the verbatim gate drops the unverifiable; quote-led display works; error isolation and dedup behaved correctly on real data.
- ✅ **Recall is solved.** Adaptive re-split (halve-chunk-on-`exceededContextWindowSize`) ended all session failures regardless of token density.
- ✅ **Core thesis validated.** The tool genuinely recovers real, cited, *useful* loose ends — e.g. *"how do we avoid the models going out of sync over time?"*, *"review the entire unpushed diff for convention violations"*, *"test the reconciliation against compose specs in my ~/Projects folder"*, *"give me a prompt to hand to the new agent"*.
- ❌ **Precision gate not passed.** ~25/39 items in pass 3 were noise. Not hallucination — real text, wrongly surfaced as Moritz's intent.

## Root-cause diagnosis (this is the handoff)

Two causes, both now precise:

1. **The on-device ~3B model won't reliably emit structured JSON.** It tends to answer conversationally (seen since the Task-1 round-trip). So the classifier's "return a JSON array of indices" frequently fails to parse → it **fails open → keeps everything → the filter no-ops**. The same freeform unreliability weakens extraction. **This is the dominant blocker.**
2. **Claude Code records skills, `/code-review` output, subagent results, and injected system text as `type:user` turns.** So skill bodies (*"Do NOT offer it upfront"*), review findings (*"readFile rejection… is not caught"*), and pasted agent briefs read like the user's prose. The transcript's own metadata can't separate them (`promptSource: typed` on a pasted brief), and only *some* carry filterable markers.

## Next steps (do these before re-running the gate)

1. **Guided generation (`@Generable`) for the Foundation Models provider** — force the on-device model into a valid structured response for classification *and* extraction, instead of parsing freeform text. This is the Task-1 note come due and is the most likely single fix for precision (and extraction quality). Note the on-device 4096-token window still applies — keep the adaptive re-split.
2. **Filter Claude Code's noise envelopes** — skill bodies, `/code-review`/workflow output, subagent-result blocks (`<usage>`, `<subagent_tokens>`, `</tool_uses>`…), `[Request interrupted…]`, and pasted-brief patterns. Extend `TranscriptParser`'s injected/command detection.
3. **Reconsider the classifier's fail-open default** once (1) makes structured output reliable — with reliable parsing, a stricter (fail-toward-drop) policy becomes safe and precision-positive.
4. Then re-run the acceptance slice; target: the ~12–14 genuine items surface, the ~25 noise items don't.

## Carried minor findings (deferred, from per-task + final reviews)

Logged for a cleanup pass; none block the above: FoundationModelsProbe unavailable-reason interpolation; `claude -p` stdin write is fire-and-forget (SIGPIPE risk if child closes early); `decodeCandidates`/`decodeIndices` slice first-`[`..last-`]` (trailing `]` prose can drop a batch); `Checkpoint` CLI/model bare-name collision (rename `CheckpointCommand`); `looseends` ignores `project` arg when `--all` given; N+1/2N per-project queries and `Calendar.current` locale/TZ in age/dormancy; `digest` abstract says "active" but iterates all states.

## Design decisions made during execution (for future-me)

- **Session fingerprint dropped its content-hash** → `session:<sessionID>` (aligns runtime with the v3 backfill; honors "ingest a session once at end"). Trade-off: a *resumed* session re-ingested with new content won't re-extract — accepted per spec.
- **IntentClassifier fails open** (keeps messages on any classifier hiccup) so a glitch never silently zeroes extraction — but see Next Step 3: this becomes too lenient once structured output is reliable.
