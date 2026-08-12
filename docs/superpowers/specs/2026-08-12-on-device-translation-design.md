# On-device translation — generated text read in German, stored as an indexed alternate stream

**Date:** 2026-08-12
**Status:** design, ready for review
**Scope:** the macOS `Translation` framework applied to text Pensieve's own models produced —
the "Last Work Done" narration (automatic), plus loose-end summaries and node names (on demand) —
stored in a disposable cache, indexed alongside the English original so the German you read is also
the German you can find, plus a zero-result query backstop for content that never gets translated.

Deliberately excluded: translating captured content (git commit subjects, event summaries,
transcript text), translating loose-end **quotes** or transcript windows in any circumstance,
localizing App Intents / Siri / Shortcuts phrases (a standing deferred item), and translating
anything the `pensieve` CLI or the launchd sync agent *generates* — those read translations, never
write them.

All line references are against `main` at `907b4fc`.

## Problem

The app's chrome is localized to German. Its content is not, by an explicit decision recorded in
`CLAUDE.md`: node names, loose-end quotes, descriptions, event summaries, roles and transcript text
are never localized, and content-mixed frames stay English-fallback. That decision is right for
*captured* text — a commit subject is a verbatim artifact, and a quote that no longer matches its
transcript is a broken citation.

But it also covers text Pensieve *generated*: the narration paragraph, loose-end summaries, and
auto-birthed strand names. Those are not verbatim anything. They are the model's own prose about
English source material, and there is no reason a German reader must read them in English.

The obvious implementation — translate at display time — is a trap, for two reasons that only became
visible on reading the code.

### Display-time translation breaks retrieval

`EmbeddableCorpus.swift:53` and `:59` define what the BM25 index ingests:

- node documents → `node.name` + `node.description`
- loose-end documents → `looseEnd.text` + `looseEnd.quote`

Narration is absent from the corpus. Node names and loose-end summaries are not.

`FTSQuery.swift:65` joins text clauses with `" AND "`. That is not a ranking detail — it is a cliff.
A term that appears nowhere in the index does not demote a row, it returns **zero rows**. So a
display-only translation produces this sequence: the sidebar shows a German strand name, the user
types the name they can see, and search returns nothing, because the index holds the English.

Repairing that downstream by translating the query back toward English does not work, because
translation is not an involution. `Hintergrund-Synchronisierung` → `background synchronization` need
not land on the original `Background sync`, and under AND semantics one word off is still zero rows.
Building a feature that breaks retrieval plus a second feature that partially repairs it is worse
than building neither.

### "What the model generated" is not a computable predicate

`Node.swift:23` — `name` carries no provenance column. `Node.swift:28` — `description` is commented
*"LLM- or user-authored"*; the model records the ambiguity rather than resolving it. An auto-birthed
strand name, a name typed into the New Node modal, and a name set by in-place rename are
byte-identical in storage. There is no test at display time that distinguishes them, so
"translate the generated ones" would translate names the user wrote, including deliberately-English
ones.

Node names also leave the app through Spotlight donation, `pensieve mcp`, `pensieve list` and window
titles. The launchd sync agent has no UI locale at all.

## The resolution — translations are stored, indexed, alternate content

Translate once, persist the result, and feed it into the search corpus as an additional document.
Then the string rendered on screen and the string in the index are *the same string*, and both
problems dissolve: there is no round-trip to be lossy, and no need to know who authored the source,
because translation becomes an explicit act on a specific field rather than a locale-driven
substitution applied to everything.

This is the same shape as three things already shipped — `narration-cache.sqlite` (disposable prose
shared across app/CLI/MCP), `search-index.sqlite` (rebuildable, hash-guarded), and the
`EmbeddableItem.hash` invalidation pattern. It introduces no new architectural concept.

## Decisions

1. **A separate store, not the canonical one.** `pensieve.sqlite` is "the only store that will ever
   sync." A translation is a disposable derivation, regenerable from its source at any time, so it
   belongs nowhere near CloudKit's future surface and must not cost a canonical migration.
2. **Extra rows, never extra columns.** FTS5 normalises `bm25()` by a row's total token count across
   all columns — the measured lesson behind `document_files` (P@1 0.395 → 0.378, McNemar p = 0.017,
   n = 1500). Translated text is a separate document.
3. **The target language is a setting, not the runtime locale.** See §Target language.
4. **Generation is app-only; reading is universal.** Direct precedent: `pensieve prime` is
   cache-read-only prose that never narrates, spawns or blocks.
5. **Automatic for narration, on demand for everything else.** Narration is the only translatable
   field absent from the search corpus, so it is the only one where automatic translation carries no
   findability consequence.
6. **The query backstop runs only on zero rows**, which is what makes it unable to regress anything.
7. **Quotes are unrepresentable, not merely un-translated.** See §Trust gate.

## Target language

The original framing was "the app's runtime locale." Rejected, for two reasons: it makes the feature
inert unless the whole UI is switched to German, and it lets a locale the user never chose (system
French, app falling back to English base) silently select a translation target.

Instead, **Settings ▸ Intelligence ▸ "Translate generated text to: [Off / Deutsch / …]"**, persisted
in `PensieveDefaults` so the app, the CLI and the launchd agent all read the same value when building
the corpus — the same cross-process pattern the retired `semanticSearchKey` used.

Default **Off**. With it off the feature costs exactly zero: no store file is created, no index rows
are produced, no model asset is loaded. This is a deliberate response to a shipped defect — the
vector engine's "default-off" did not mean off, because a `true` persisted from an earlier default-on
kept it live and diluting results, and a *disabled* feature still created its index and loaded a
model on every launch (`b36f745`). Off means nothing runs.

The picker also decouples reading language from UI language, which is the likelier real want: German
summaries with English chrome.

## Availability

The headless `TranslationSession(installedSource:target:)` initializer is **macOS 26.0+**;
`TranslationSession.Strategy` (`.lowLatency` / `.highFidelity`) is **26.4+**. macOS 15 offered only
the SwiftUI-attached `.translationTask`, which would have made the query path impossible.

`Package.swift` stays `.macOS(.v14)` and `project.yml`'s deployment target stays 15.0 —
`@available(macOS 26, *)` annotations compile fine in a v14 package, and below 26 the seam simply
returns nil, which every caller already handles. Verified against
`MacOSX26.5.sdk/…/Translation.swiftmodule/arm64e-apple-macos.swiftinterface`.

**One view is unavoidable.** A headless session cannot prompt for a language-pack download
(`canRequestDownloads`, `isReady`, and `TranslationError.notInstalled` exist precisely to report
this). First-run acquisition therefore uses a single Settings-hosted `.translationTask` view. It is
the only place in the design where a view is required, and it is the correct native mechanism for it.

## Components

### `TranslationStore` — `translation-cache.sqlite`

New file in the support dir, alongside the other disposable indexes. Never synced. One table keyed
`(field, sourceTextHash, targetLanguage) → translatedText`.

Invalidation is free and needs no explicit sweep: re-extraction changes the source text, which
changes the hash, which orphans the stale row — the same mechanism `EmbeddableItem.hash` already
relies on (`EmbeddableCorpus.swift:17` and `:23`). Orphans are reclaimed by the same
prune-against-live-keys pattern `AppModel.pruneNarrationCache` uses.

`field` is an enum with exactly four cases:

```
narration · looseEndText · nodeName · nodeDescription
```

There is no case naming a quote or a transcript message. See §Trust gate.

### `Translator` — a protocol seam in Kit

Mirrors `LLMProvider`: Kit declares the protocol, and the `TranslationSession`-backed implementation
is `@available(macOS 26, *)`. `LanguageAvailability.status(from:to:)` gates each direction
independently. Any `TranslationError`, an uninstalled pack, or a pre-26 OS returns nil.

The seam exists primarily for testability — a stub `Translator` lets every corpus, resolver and query
test run deterministically without a language pack or macOS 26. See §Testing.

### `EmbeddableCorpus.gather` gains the translation store as a source

Translated text enters as additional `EmbeddableItem`s carrying the owning node's live `state`, so
the existing `NodeState.searchable` allow-list and the archived-content flag continue to govern them
unchanged.

Two constraints:

- **The translated loose-end document carries the text only, never the quote.** `:59` currently joins
  `looseEnd.text` and `looseEnd.quote` into one document; including the English quote in the German
  document would both violate the trust gate and manufacture duplicate hits.
- **`SearchHitResolver` collapses original-plus-translation matches to one hit** per underlying item.
  One shared resolver already re-resolves every hit against canonical; the dedup belongs there, with
  the rest of the grounding defense, not in the callers.

### Document identity — a `language UNINDEXED` column, not an encoded `item_id`

A translated document must resolve back to the same underlying entity as its original, so the
resolver can dedup. The tempting shortcut — suffixing `item_id` with a language tag and parsing it
back out — is stringly-typed and would put a parse step inside the grounding path.

Unnecessary, because the `documents` table already carries its metadata this way
(`SearchIndexStore.swift:65-68`):

```
CREATE VIRTUAL TABLE documents USING fts5(
  text,
  item_id UNINDEXED, kind UNINDEXED, node_id UNINDEXED, state UNINDEXED,
  tokenize = 'unicode61 remove_diacritics 2')
```

So: bump the disposable store to **schema v3** and add `language UNINDEXED` beside them, with `""`
meaning the untranslated original. `item_id` stays identical across a document and its translation,
which makes resolver dedup a group-by rather than a parse.

This does not weaken decision 2. An FTS5 `UNINDEXED` column is not tokenized and contributes no
tokens, so it cannot affect `bm25()` normalisation — that decision is about the translated *text*
being its own row, which it is. The schema bump is free: the store is rebuildable, and a version
mismatch already triggers a full rebuild (`SearchIndexStore.swift:54`, `:80`).

No new index machinery is needed beyond that column. `SearchIndexStore.rebuild(items:corpusHash:)` is
a whole rebuild guarded by `meta.corpus_hash` (`SearchIndexStore.swift:112`, `:138`), so a new
producer inside `gather` shifts the hash on its own and existing invalidation handles it.

## Surfaces

### Narration — automatic, one string with three consumers

Translation runs after narration resolves and before first render.

The load-bearing detail: `DetailView.swift:69` feeds the narration into the in-node find document via
`findableText(lastWorkDone, anchor: .narration)`, and `:134` feeds it into `RecallMarkdown.render`
for share/copy. The display string is therefore resolved **once into a single local** that all three
consumers read. Coherence between what is on screen and what ⌘G walks becomes structural rather than
a discipline to maintain — this is exactly the defect class the in-node-find × slice-A merge produced,
where the narration slot moved on screen but not in `NodeFindDocument.make`.

Two sub-decisions:

- **Translate before first render**, giving one atomic spinner → German transition rather than an
  English→German flicker. The `.task` state machine already needed two adversarial spec reviews plus
  an Opus review to get its render windows right (reset-on-node-change, `isNarrating` reset per
  entry, `Task.isCancelled`, prose-first render gated on `loadedNodeID == node.id`); a second
  stale-render window is not worth a few hundred milliseconds. Cached translations make the second
  open instant anyway.
- **Share/copy exports what is displayed.** One string feeding every consumer is the point; a share
  action that silently changes language would be surprising. Readers who want English turn the
  setting off.

### Loose-end summaries and node names — on demand

A native `.contextMenu` **Translate** action on loose-end rows and node rows: translate → write to
store → swap the displayed string.

The write lands in a different database, so it will not trip the canonical `ValueObservation` — the
same shape as the Node-only-writes problem slice 4 solved with an explicit `refresh()`. The action
therefore triggers a search-index sync explicitly, detached off the main actor (as the BM25 review's
watch-path fix established), coalesced through the existing tested `Debouncer` actor so translating
eight loose ends in sequence does not cause eight whole rebuilds.

**Accepted trade-off.** On-demand translation and index-for-findability are in mild tension: only
items actually translated become findable in German, so the German index is sparse by construction.
Accepted — translation is primarily a reading aid, and findability is a bonus over what has been
read. A per-node bulk translation is an easy additive follow-up if dogfooding shows the sparsity
bites; pre-emptively translating text that is never looked at is the eager cost this design exists to
avoid.

### Query backstop — zero rows only

`SearchQueries.swift:47` is the single chokepoint through which every query reaches
`FTSQueryBuilder.build`.

On zero rows, translate the raw query in the **opposite** direction — configured target → English —
and retry exactly once. `Strategy.lowLatency` for queries; `.highFidelity` for prose.

**No language detection.** Detection over a two-word query is unreliable, and it is unnecessary:
attempting a German→English translation of an already-English query yields a no-op or garbage, and
because the branch runs only after an empty result, there was nothing to lose. This is the entire
safety argument — the backstop cannot regress any query that currently returns rows, because it never
executes for one.

Its residual value, now that the corpus carries German documents, is over content that never gets
translated: git commit subjects, event summaries, and file paths. German compounding keeps it from
being redundant — a user typing `Hintergrundsync` against a stored `Hintergrund-Synchronisierung`
still hits the AND cliff.

## Trust gate

Untouched, and structurally so.

- **Quotes and transcript windows are never translated**, enforced by `TranslationField` having no
  case that could name them. Same technique as `FTSQuery.Shape`: illegal states are compile errors,
  not review findings.
- `TranscriptVocabulary.injectionMarkers` and `TranscriptParser.isInjectedOrCommand` are not read,
  written, or referenced. Extraction never sees a translation.
- A translated loose-end summary above a verbatim English quote is the *honest* pairing: this is what
  the model understood, in your language; these are the original words, byte-for-byte checkable
  against the transcript.
- Narration is already outside the strict cited gate (best-effort, allowed to return nil). Failing to
  translate it degrades to English, which is strictly more honest than any fabrication.

This design changes only which real stored rows are eligible to be returned and rendered. It never
changes what may be said about them.

## Degradation

Every failure returns the English original, and nothing throws into a render, capture or ingest path:

| Condition | Behavior |
|---|---|
| Setting Off | Fully inert — no store file, no index rows, no model load |
| Pre-macOS 26 | Seam returns nil; English everywhere |
| Language pack not installed | English, plus a Settings hint offering the download |
| Any `TranslationError` | English; no retry |
| Translation store unreadable | Treated as "no translations exist" |
| Stale translation (source text changed) | Hash miss → English until re-translated |

## Testing

All testable logic in Kit; the app target gets an `xcodebuild` build plus a non-blocking smoke-launch
of the inner binary with throwaway `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB`.

A **stub `Translator`** is essential: no test may depend on an installed language pack or on macOS 26.

- `TranslationStore`: round-trip, hash invalidation, orphan pruning, `TranslationField` exhaustiveness.
- `EmbeddableCorpus.gather` with translations present: extra rows appear with the owning node's live
  `state`; the translated loose-end document contains the text and **not** the quote.
- `SearchHitResolver`: original and translation both matching yields exactly one hit, grouped on the
  shared `item_id`. Also that a translated document alone still resolves — the German row must be a
  first-class hit, not merely a dedup victim.
- `SearchQueries` backstop, **both directions asserted** — zero rows invokes the translator;
  a non-empty result does **not**. The negative assertion is explicit and mutation-checked both ways:
  the BM25 review found two vacuous tests that still passed with the behavior removed entirely, and a
  backstop test that only checks "results came back" would pass with the guard deleted.
- `FTSQueryBuilder` is unchanged and its tests must stay so — translation happens on the raw string,
  before the builder, so the injection-surface guarantee is untouched.

## Verification gate — pre-registered

Adding a second language's documents roughly doubles collection size, shifting corpus-wide IDF and
`avgdl` for every term including English ones. This project has already been bitten once by exactly
this class of innocent-looking schema choice, so the gate is fixed in advance rather than argued
after the numbers arrive.

- **Hypothesis:** English P@1 does not regress below the 0.395 baseline.
- **Instrument:** the committed gold set and probes at
  `docs/superpowers/measurements/2026-07-28-retrieval-recall/`.
- **Decision rule:** if the paired comparison regresses at p < 0.05 (McNemar, n = 1500 as before),
  ship the pre-specified fallback — **a separate FTS table per language**, which makes English
  ranking byte-identical *by construction* rather than by measurement. This is the same fallback that
  shipped for `document_files` when the primary design was rejected by its own gate.
- **Prerequisite:** the gate is meaningless against an empty German index, so it needs a one-off
  offline bulk translation of the eval corpus. This is a real task in the plan — and notably, it is
  the eager-translation cost the product design deliberately avoids paying.

## Size

This is a slice, not a small addition: new store, new seam, corpus-producer change, resolver dedup,
query backstop, Settings knob, two localized surfaces, and an eval gate with a corpus-translation
prerequisite. Comparable to archive-nodes or Settings-v2; smaller than the BM25 work.

## Out of scope

- Translating captured content — commit subjects, event summaries, transcript text. These are
  verbatim artifacts.
- Translating quotes or transcript windows, under any setting. Structurally excluded.
- Cloud translation. The `Translation` framework is on-device; the cloud `LLMProvider` serves
  narration only and is not involved here.
- Translating text the CLI or launchd agent generates. They read translations into the corpus and
  never write them.
- Localizing App Intents / Siri / Shortcuts phrases, or the `pensieve` CLI — a standing deferred item
  in `backlog.md`, unchanged by this work.
- Per-node bulk translation. Additive follow-up if on-demand sparsity proves annoying.
- Translating node `description` automatically. It is in the corpus like `name`, so it follows the
  same on-demand rule; the field exists in `TranslationField` for the explicit action only.
