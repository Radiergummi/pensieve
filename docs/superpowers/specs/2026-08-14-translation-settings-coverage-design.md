# Translation settings — pack management, measured coverage, and an explicit backfill

**Date:** 2026-08-14
**Status:** design, ready for review
**Scope:** the Settings surface the on-device translation slice never built — a real target-language
picker over what this Mac can actually translate, language-pack status with a download affordance and
a link to the OS pane that owns pack management, a measured coverage readout, and one explicit,
cancellable, resumable backfill that translates the rest of the corpus.

Deliberately excluded: ambient translation in the launchd sync agent (it stays a reader, per the
translation spec's own boundary), any CLI surface, and translating anything new — this adds no case to
`TranslationField` and touches no verbatim text.

All line references are against `main` at `4068cd9`.

## Problem

The translation slice shipped its engine and skipped its control surface. `IntelligenceSettingsTab.swift:110-130`
is the entire user-facing translation feature:

```swift
Picker("Translate generated text to", selection: $translationTarget) {
  Text("Off").tag(TranslationTarget.off)
  Text(verbatim: "Deutsch").tag("de")
}
if translationTarget != TranslationTarget.off {
  if #available(macOS 26, *) {
    Text("Prepare translation")
      .translationTask(source: …, target: …) { session in try? await session.prepareTranslation() }
  }
}
```

Three defects, in rising order of consequence.

**1. The download is unmanaged and unreported.** The `.translationTask` is attached whenever a target
is set, so it re-fires on every Settings open, and its host is a bare `Text("Prepare translation")`
that reads as leftover debug UI. There is no indication whether the pack is installed, downloading, or
absent — and a headless `TranslationSession(installedSource:)` returns nil for an absent pack, so the
one condition the user must be able to see is the one nothing reports. The slice's own spec promised
this ("Language pack not installed → English, plus a Settings hint offering the download",
`2026-08-12-on-device-translation-design.md:290`); the hint was never built.

**2. The picker is a hardcoded list of one.** `TranslationTarget.supported = ["de"]` was narrowed
deliberately, on the argument that "each one added doubles a slice of the search index, which is a
measured cost". That argument was then *retired by its own measurement*: the pre-registered ranking
gate shipped as built with English P@1 statistically indistinguishable from baseline (McNemar p =
1.000, `measurements/2026-08-12-translation-ranking/README.md`). Only one target is active at a time,
so the doubling is bounded at exactly the case that gate cleared.

**3. The feature is inert, and nothing says so.** The live store holds **2 translations** — both
narration:

```
$ sqlite3 …/Pensieve/translation-cache.sqlite "select field, language, count(*) from translation group by 1,2;"
narration|de|2
```

Against a translatable corpus of **1,294 distinct texts** (measured read-only against the live
canonical store, using the corpus's own eligibility):

| unit | rows | distinct texts |
|---|---|---|
| node `name` (active or archived) | 285 | 279 |
| node `description` (non-empty) | 155 | 155 |
| loose-end `text` (`label <> 'noise'`) | 882 | 860 |
| **total distinct translatable units** | | **1,294** |

So coverage is **0 of 1,294** for everything the search index can use. Worse, two of the three fields
have no writer at all: `EmbeddableCorpus.gather` looks up `.nodeName` and `.nodeDescription`
(`EmbeddableItem.swift:157-172`, reached from `:101`), and no production caller ever passes those
cases — a grep for
`translate(field:` finds only `.looseEndText` (three list sites plus the detail pane) and `.narration`
(automatic on open). The only thing that ever populated them was the eval probe. A user who switches
to German sees English node names forever and has no way to learn why.

Turning German on and getting two translated paragraphs is indistinguishable from a broken feature.
That is the actual bug; pack status and language choice are the two smaller ones next to it.

## Decisions

**Explicit backfill, not ambient.** The button is pressed or nothing happens in bulk. The sync agent
stays a reader of translations, exactly as the translation spec drew the line, so there is one writer
of `translation-cache.sqlite` and no arbitration between a background slice and a foreground run.

**Coverage is defined over the search corpus, not over "everything".** The denominator is the set of
`(field, sourceText)` pairs `EmbeddableCorpus.gather` will look up. Anything else would be a number
that cannot reach 100%.

**Counted by distinct text, not by row.** `TranslationStore` is keyed `(field, source_hash,
language)`, so two nodes named `Agent` collapse onto one stored row. The eval run verified this
directly: 278 node names resolved to 272 distinct strings, and all six collisions had real
translations. A row-count denominator would sit permanently short of its total and read as failure.

**No narration line, and narration is not backfilled.** Narration prose exists only for nodes that
have been opened, and it already translates automatically on open (`AppModel+Narration.swift:121-130`).
A "41 of 162" readout would imply 121 missing translations when what is missing is 121 *narrations* —
LLM generation, not translation. Producing them would mean running the provider over every node, which
is a different, far more expensive feature wearing this one's label. It is also the one field whose
coverage self-heals. `NarrationCache` exposes only `get`/`put` (`NarrationCache.swift:35,43`); this
design deliberately does not add enumeration to a disposable cache to compute a misleading number.

**No ETA.** The eval README records 1,303 attempts and 0 nils but no elapsed time, so any "~4 min
left" would be invented. The readout is `318 of 1,294`. An ETA becomes available honestly once one
real run has been observed, and is a follow-up, not part of this.

**No `EvalTask`.** The project's rule is that new *LLM-backed* tasks register one and take their
default model from `pensieve eval`. Nothing here calls an `LLMProvider`: translation is the on-device
`Translation` framework, which exposes no model choice to make. The `registry ↔ config` test is
unaffected.

**No new verification gate.** The state this feature produces — a corpus at ~100% German coverage — is
precisely the treated arm the ranking gate already measured (1,148 German documents over 2,878
English, p = 1.000). Re-running it against the same design would be re-asking a question that has an
answer.

## Availability, measured

`LanguageAvailability` is **macOS 15.0+**, not 26 — verified in
`MacOSX.sdk/…/Translation.swiftmodule/arm64e-apple-macos.swiftinterface:11-15`. Only
`TranslationSession(installedSource:target:)` is 26+ (`:188`). So the picker, the status line and the
coverage readout all work at the app's 15.0 deployment target; only translating itself needs 26, where
the existing seam already returns nil and every caller shows English.

Probed on this machine (`Translation`, `status(from: en, to:)` over `supportedLanguages`):

- **38** supported languages, of which **9 are English variants** reporting `unsupported` (en→en) and
  drop out of the list by that status alone — no hand-maintained exclusion needed.
- **29** usable targets, **22 installed**, 7 needing download (`ar-AE`, `hi`, `id`, `pl`, `ru`, `th`,
  `uk`).

Two identifier facts, both probed rather than assumed:

- **`minimalIdentifier` is the right persisted form.** The framework reports region- and
  script-distinct entries as distinct languages (`zh` with `max=zh-Hans-CN`, `zh-HK` with
  `zh-Hant-HK`, `zh-TW`, `pt` with `max=pt-Latn-BR`, `pt-PT`, `de`, `de-CH`, `es`, `es-MX`, `es-US`,
  `fr`, `fr-CA`, `it`, `it-CH`, `ar-AE`), and every one of those 29 minimal identifiers round-trips
  through `Locale.Language(identifier:)` unchanged. Persisting the framework's own minimal identifier
  therefore loses nothing. (`maximalIdentifier` would store `zh-Hans-CN` where the user chose `zh`,
  and a bare `languageCode` would collapse `zh-HK` onto `zh` — silently translating into the wrong
  script.)
- **Display names must use `forIdentifier:`, not `forLanguageCode:`.**
  `Locale(identifier: id).localizedString(forIdentifier: id)` yields `Deutsch`, `Deutsch (Schweiz)`,
  `中文（香港）`, `português (Portugal)`. The `forLanguageCode:` variant drops the qualifier and renders
  three distinct Chinese options as three identical rows labelled `中文`.

## Components

### `TranslatableUnit` + `TranslatableCorpus` — Kit, tested

```swift
public struct TranslatableUnit: Hashable, Sendable {
  public let field: TranslationField
  public let sourceText: String
}

public enum TranslatableCorpus {
  /// Every (field, text) pair `EmbeddableCorpus.gather` will look up a translation for, deduplicated.
  public static func gather(_ database: any DatabaseReader) throws -> [TranslatableUnit]
}
```

Eligibility must equal the corpus's, and this project's recurring defect class is two paths that were
supposed to agree and drifted (the BM25 branch had to extract `SearchHitResolver` for exactly this
reason; the loose-end-resolution branch found the index filter and the canonical re-check disagreeing
about `isOpen`). So the two fetch predicates are **extracted** from `EmbeddableCorpus.gather` into
internal helpers that both producers call:

- nodes: `state == .active || state == .archived` (`EmbeddableItem.swift:94-95`)
- loose ends: `LooseEnd.where { $0.label.neq(LooseEndLabel.noise) }` (`:111`)

`gather` keeps its current behaviour byte-for-byte; only the fetch moves. The anti-drift pin is a
property test in both directions:

1. For every unit, a `TranslationStore` containing only that unit makes `EmbeddableCorpus.gather(…,
   language: "xx")` emit a translated document.
2. `gather` emits no translated document for any `(field, text)` outside the unit set.

Both are mutation-verifiable: deleting a field from `TranslatableCorpus` fails (1); widening it fails
(2). This project has shipped two vacuous tests that passed with the behaviour deleted, so each test
here is stated with the mutation it must fail under.

### `TranslationCoverage` — Kit, tested

```swift
public struct TranslationCoverage: Sendable {
  public struct Field: Sendable {
    public let field: TranslationField
    public let translated: Int
    public let total: Int
  }
  public let fields: [Field]
  /// The units with no stored translation — what the backfill consumes.
  public let missing: [TranslatableUnit]
  public var translated: Int { … }
  public var total: Int { … }

  public static func measure(units: [TranslatableUnit], store: TranslationStore,
                             language: String) -> TranslationCoverage
}
```

Pure over one store read per unit. `language == off` yields a zeroed coverage, never a store open.
`missing` is what the backfill consumes, so the number shown and the work done cannot disagree — they
are the same list.

### `TranslationBackfill` — Kit, tested

```swift
public struct TranslationBackfill: Sendable {
  public static func run(units: [TranslatableUnit], store: TranslationStore, translator: any Translator,
                         language: String,
                         progress: @Sendable (Int, Int) -> Void) async -> Int
}
```

Five properties, four of them scars from the eval run that already did this work once
(`measurements/2026-08-12-translation-ranking/README.md` § "What surprised us"):

- **Serial.** One item at a time. The generator that completed was serial; on-device throughput under
  concurrency is unmeasured, and this is not the change in which to find out.
- **Idempotent.** Check-then-skip against the hash-keyed store before calling the translator, so a
  second press pays only for what is missing. The eval generator lacked this, died at 522/870, and had
  to be given it before it could be re-run.
- **Resumable by construction.** Each `put` commits its own row, so a quit, a crash, or a cancel keeps
  every translation already made. There is no checkpoint to corrupt because there is no checkpoint.
- **Cancellable.** `Task.isCancelled` is checked per item and returns cleanly. Partial work stands.
- **Never throws, never retries a nil.** A nil translation is skipped and counted as attempted; the
  next run will try it again, which is honest — an absent pack is a condition that changes.

Returns the number newly written, so the caller knows whether to reindex at all.

### `TranslationTarget` — Kit, changed

`supported = ["de"]` is removed. `resolved()` keeps its signature and its contract ("off for unset,
English, or anything unusable") but validates **shape** instead of membership:

```swift
guard !stored.isEmpty, stored != sourceLanguage,
      let code = Locale.Language(identifier: stored).languageCode,
      Locale.LanguageCode.isoLanguageCodes.contains(code) else { return off }
```

The doc comment's original worry — that an unrecognised value "would reach the framework, which would
fail per call and log on every render" — is already answered downstream: `SystemTranslator.translate`
checks `status(from:to:) == .installed` before constructing a session (`Translator.swift:31`), and
`displayed(field:sourceText:)` is a pure store lookup that never reaches the framework at all. The
comment is rewritten to say so rather than left asserting a reason that no longer holds.

Probed: `de` ✓, `zh-Hans` ✓, `pt-BR` ✓, `de-DE` ✓, `klingon` ✗ (not an ISO 639 subtag) — so
`TranslationTargetTests.anUnsupportedLanguageResolvesToOff` keeps both its assertion and its intent.
`tlh` now resolves to itself, which is correct: it is a real ISO code, and the framework reports it
unsupported, so translation returns nil and English shows.

Writers only ever persist an identifier `LanguageAvailability` reported, so shape validation is a
backstop against a hand-edited plist, not the primary guard.

### `TranslationSettingsSection.swift` — app, thin, new file

Extracted rather than grown in place: `IntelligenceSettingsTab.swift` is 261 lines and CI runs
`swiftlint --strict` with a 400-line cap.

**Target picker.** Options loaded once on appear: `await LanguageAvailability().supportedLanguages`,
each with `status(from: en, to:)` resolved concurrently, keeping `!= .unsupported`, sorted by localized
display name, tagged with `minimalIdentifier`. `Off` stays first. Rows label installed vs
downloadable. A persisted target the framework no longer reports is still shown as selected rather
than silently blanking.

**Pack status + download.** One adaptive line — ready / needs download / downloading / requires macOS
26 — and a **Download** button that mounts the `.translationTask` **only while pressed**, then
re-reads status. This is the fix for defect 1: the task stops being a permanent resident of the view
hierarchy and becomes what it always should have been, the action behind a button. It remains the only
view-attached translation in the app.

**"Manage installed languages in System Settings ↗"** →
`x-apple.systempreferences:com.apple.Localization-Settings.extension`, verified present on this machine
as the pane owning the "Translation Languages" UI (its binary carries that exact string). Deleting a
pack is OS-only, so linking out is the honest ceiling of "manage" — the app can request a download and
report status, and nothing more.

**Coverage + backfill.** `Translated 318 of 1,294`, a determinate `ProgressView` while running, and
one button that is `Translate remaining` or `Stop`. Zero missing units disables it and says so. So
does a pack that is not installed: 1,294 calls that each nil out is not a run worth starting, and the
Download button directly above it is the actual next step.

### `AppModel+Translation.swift` — app, thin

The backfill `Task` is owned by `AppModel`, not the view, so closing Settings does not kill a run in
flight and reopening it shows the run still going. Progress is `@Observable` state on `AppModel`
(`translationBackfillProgress: (done: Int, total: Int)?`, nil when idle).

On completion: bump `translationRevision` (repaint panes with new text) and schedule **one**
`translationDebouncer` pass — the existing 0.4 s trailing-edge coalescer, whose doc comment already
states the requirement that translating many items must cause one whole-corpus rebuild, not many.
Changing the target language or switching to Off cancels a run in flight.

### Localization

New chrome keys hand-authored into `Localizable.xcstrings` for `en` + `de`, per the standing gotcha
that `xcodebuild` does not populate the catalog. Language display names are `Text(verbatim:)` content,
not chrome, and are never localized into a catalog key — they come from `Locale` and are shown in each
language's own endonym.

## Trust gate

Untouched, and structurally so:

- `TranslationField` gains no case. Quotes and transcript messages remain unreachable because there is
  no value to pass, which is the type's stated purpose.
- The backfill writes only the three fields `EmbeddableCorpus.gather` already reads. It cannot make a
  translation appear anywhere a translation could not already appear.
- Cited quotes, transcript windows and captured content are not read by any component here.
- No LLM provider is involved. Translation is the on-device `Translation` framework only.

## Degradation

| Condition | Behavior |
|---|---|
| Target Off | Coverage zeroed without opening the store; backfill button absent |
| Pre-macOS 26 | Picker and status render; status line says translation needs macOS 26; backfill disabled |
| Pack not installed | Status says so and offers Download; backfill button disabled (a run would nil out on every unit) |
| `LanguageAvailability` returns nothing | Picker falls back to the persisted target as its only row |
| Download declined or fails | Status returns to "needs download"; nothing else changes |
| Backfill cancelled or app quit mid-run | Every completed translation persists; re-press resumes |
| Individual translation returns nil | Skipped, counted attempted, retried on a later run |
| Translation store unreadable | Coverage reads 0 of N; backfill no-ops |
| Language switched after a backfill | Old language's rows stay on disk (disposable); the index rebuild drops their documents, because `gather` looks up only the current language |

## Testing

Kit carries every testable rule; the app target gets an `xcodebuild` build plus a non-blocking
smoke-launch of the inner binary with throwaway `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB`. A stub
`Translator` is mandatory — no test may depend on an installed pack or on macOS 26.

- `TranslatableCorpus`: the two-direction property test against `EmbeddableCorpus.gather` above, each
  stated with the mutation it fails under. Plus: `noise`-labelled ends excluded, `muted` nodes
  excluded, archived nodes included, empty descriptions excluded, duplicate texts deduplicated.
- `EmbeddableCorpus`: existing tests must pass unchanged. The predicate extraction is a refactor, and
  the suite is the evidence for that claim.
- `TranslationCoverage`: partial coverage counts, `off` yields zero and touches no store, `missing`
  is exactly the complement of what is stored, duplicate source texts count once.
- `TranslationBackfill`: writes every missing unit; a second run writes nothing (idempotence);
  cancellation mid-run leaves earlier writes intact and stops calling the translator; a nil-returning
  translator writes nothing and does not loop; progress is reported monotonically and ends at the
  total attempted.
- `TranslationTarget`: the four existing tests keep passing, with `klingon` still resolving to off
  under the new shape validation, plus `zh-HK` and `pt-PT` resolving to themselves.

## Accepted limitations

- **RTL content is not laid out specially.** `ar-AE` is offered because the framework offers it;
  translated content will render in views built for LTR. Chrome is unaffected. Revisit if an RTL
  target is actually used.
- **Backfill throughput is unknown** until one run is observed — hence no ETA, and hence serial.
- **Switching languages costs a full pass** for the new language. The store keeps both; disk is the
  only cost, and the file is disposable.
- **Coverage is a store lookup per unit** (1,294 reads today). If that proves slow enough to notice on
  Settings open it becomes one grouped query; not designed around in advance.

## Out of scope

- Ambient or scheduled translation in the launchd sync agent, and any CLI surface. The agent and CLI
  read translations and never write them; this design does not change that.
- Backfilling or bulk-generating narration. See §Decisions.
- Translating captured content, quotes, or transcript text, under any setting. Structurally excluded.
- Per-node bulk translation — a global backfill subsumes the translation slice's deferred follow-up.
- Deleting language packs from within the app. The OS owns pack lifecycle; the design links to it.
- Multiple simultaneous target languages. One target, one index language, as today.

## Size

A slice, comparable to the Settings-v2 surface: three new tested Kit types, one predicate extraction
out of a load-bearing corpus producer, one `TranslationTarget` contract change with its tests, one new
app Settings file with an async availability probe and a cancellable owned task, and localized chrome.
Smaller than the translation slice itself — no new store, no schema change, no query-path change, and
no verification gate, because the gate this would need has already been run and passed.
