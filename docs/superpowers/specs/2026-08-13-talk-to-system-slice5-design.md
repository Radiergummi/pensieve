# Talk to the system, stage 1 — describe it, get a node (three-pane slice 5)

**Date:** 2026-08-13
**Status:** design approved; **revised after two adversarial reviews** (see "What the reviews changed")
**Slice:** Track A / three-pane app, slice 5 of 6 (`specs/2026-07-05-pensieve-app-three-pane-design.md:170`)
**Backlog entry:** "App: capture & instruct by talking to the system" (§ heading, ~`backlog.md:1345`)

## Purpose

Type a sentence describing something you are about to work on; get a node whose **name** is a
readable label, whose **description** is your sentence verbatim, and whose **kind** and **parent**
are derived deterministically. The lightweight counterpart to auto-birth from ≥2 captured events —
that path waits for evidence, this one starts from intent.

**Stage 2** (an embedded conversational agent driving organizing verbs and grounded Q&A) stays
deferred to its own spec, unchanged by this document.

## What this slice is deliberately NOT

**Model-assisted parenting is out of scope, on measured evidence.** The first draft had BM25 retrieve
~8 candidate parents from the typed sentence and the model pick among them. That cannot work:
`FTSQueryBuilder` **AND-joins every term** (`Sources/PensieveKit/Search/FTSQuery.swift:65`), so a
sentence retrieves only documents containing *every* word. Measured against the live index
(2,962 docs — 281 node, 875 loose_end, 1,806 event):

| query as the builder emits it | rows | node rows |
|---|---|---|
| `"look" AND "into" AND "why" AND "background" AND "sync" AND "stopped" AND "spawning"*` | **0** | 0 |
| `"add" AND "a" AND "settings" AND "tab" AND "for" AND "source" AND "management"*` | **0** | 0 |
| `"pensieve" AND "widget"*` | **0** | 0 |
| `"background" AND "sync"*` | 7 | **0** |
| `"pensieve"` (single term, for contrast) | 53 | — |

Every realistic quick-add sentence retrieves **nothing**, so the parent suggestion would always fall
through to its default — inert by construction, not merely weak.

The replacement that *does* work is recorded for the follow-up increment: aggregating owning nodes
across **all three** hit kinds under OR semantics produces a concentrated winner (measured: 18/5/4
and 20/12/5 for two probe sentences), because topic vocabulary lives in events and loose ends —
2,681 of 2,962 documents — while node documents are `name — description`, i.e. what a project *is*
rather than what a task *is about*.

**That increment is gated on a measurement, not on an argument.** See "Deferred, with triggers".

## What already exists (verified against `main` at `8a97a0f`)

- **`Ingester.nameStrand`** (`Sources/PensieveKit/Ingest/Ingester.swift:366-389`) already writes a
  **model-authored `name` and `description`** onto a canonical `Node`. So this feature is **not**
  Pensieve's first model-written identity — it is the second, and the first *user-initiated* one.
- **The label gate already exists.** `Ingester.sanitizeStrandName` (`:257-270`) strips list markers
  and quotes, then requires `TextQuality.isTerseLabel` (`Support/TextQuality.swift:37-41`): non-empty,
  ≤ 60 chars, and no multi-sentence shape. Its scar comment (`:265-268`) records the exact failure
  this feature would otherwise rediscover — a 101-char, commit-message-shaped name in the sidebar.
- **`LLMProvider`** (`LLM/LLMProvider.swift`) requires only `complete`; three structured methods are
  protocol extensions overridden by `FoundationModelsProvider`. **This slice adds no method** — a
  label is free text, so `complete` is the whole seam.
- **`NodeCommands.add`** (`Query/NodeCommands.swift:34-45`) accepts `name`/`kind`/`parent`/
  `description` and resolves the parent inside its write transaction. Unchanged.
- **`NodeFields`** (`:7-21`) has **no `description` member**, and **`NodeCommands.update`**
  (`:107-119`) explicitly *"leaves description … untouched"*. Both need changing — see Kit below.
- **The New/Edit modal** (`Sources/PensieveApp/NodeOrganizing.swift:9`) edits name, kind, context,
  colour, icon. No description field, no parent picker. `AppModel+Organizing.swift:167` passes
  `description: ""` unconditionally, so **the app cannot set a description today**.
- **Both fast create paths pass `nil` as the parent** — ⌘N (`PensieveApp.swift:45`) and the toolbar
  "+" (`RootView.swift:48`) — so every quick-add currently lands at **top level**, regardless of what
  you are looking at.
- **The commit button is `"Save"`**, `.keyboardShortcut(.defaultAction)`, and `.disabled` on an empty
  trimmed name (`NodeOrganizing.swift:63-65`); `commitNewNode` also returns early on one.
- **Eval registers three tasks** — `extraction`, `narration`, `description` (`eval-config.json`
  bars; `EvalTask.swift:22-30` fails the suite on a registry/config mismatch). **Strand naming is
  not among them**, despite being a real model-backed task.

### Measured facts

Live store, read-only, 2026-08-13:

| Fact | Value | Consequence |
|---|---|---|
| Nodes | 281 (280 active, 1 archived) | — |
| Kind vs parent | `project` at top level **182**; `strand` under a `project` **99** | **281 of 281.** Kind is a pure function of parent |
| Kinds in use | `project`, `strand` only | `domain`, `concept`, `initiative`, `task`, `topic`: zero rows |
| Sentence retrieval | 0 rows (table above) | Parent suggestion deferred |

The kind row is decisive: `NodeKind` is exactly `AppModel.defaultKind(under:)`
(`AppModel+Organizing.swift:26-29`) on every node you have ever made. **Asking a model for it buys a
field, a resolution path, and a confidently-wrong failure mode in exchange for zero information.**

## The safety property

The first draft asserted *"the model may only select or shorten; it never authors."* That was
**false for the one field the model actually produces** — a name is free text, and nothing verified
it was a shortening rather than an invention. Stated honestly instead:

> **The model authors one field — the name — and a human reads it before anything is written.
> Everything else is verbatim or derived.**

| Field | Origin | Model can invent it? |
|---|---|---|
| `description` | the user's typed text, **verbatim** | No — copied, never sent for rewriting |
| `name`, English input | model-authored label, **gated** by `sanitizeLabel` | Yes, within ≤60 chars and one sentence |
| `name`, any other language | **deterministic** word-boundary shortening of the user's text | No — the model is not called |
| `kind` | derived: `defaultKind(under: parent)` | No — not a model output |
| `parent` | the current selection, or the invocation site's | No — not a model output |

Two properties hold, and both are checkable rather than asserted:

1. **Nothing is written without human confirmation.** The modal is the gate; `Save` is a deliberate
   act, and every field is editable first. This is a stronger and more honest guarantee than the
   invariant it replaces.
2. **The cited trust gate is not involved.** Node names never render as cited provenance, and 99 of
   281 existing names are already model-authored via `nameStrand`, so this introduces no new category
   of content. `backlog.md`'s "talk to the system" entry settles that user-initiated metadata sits
   outside the gate, like `rename` — noting that its wording assumes the *name* is the user's words,
   which is why the gate above (`isTerseLabel`) does the work that assumption no longer does.

**Not touched:** `TranscriptVocabulary.injectionMarkers`, `TranscriptParser.isInjectedOrCommand`,
`isUserPrompt`, `LooseEndVerifier`, or any extraction path.

## Kit changes

### 1. Move the label gate where two callers can share it

`sanitizeStrandName` moves from `Ingester` to `TextQuality` (beside `isTerseLabel`, which it already
calls), with `Ingester`'s single call site updated. Justified by the shape now genuinely recurring —
not a speculative extraction. Its existing tests move with it.

### 2. `NodeLabeler` — the naming unit, routed by language

Given the typed text and a provider, return a label. **Measured design** — see
`measurements/2026-08-13-slice5-label-quality/`:

**English input → the model.** One `complete` call asking for a 3–6-word label, mirroring
`nameStrand`'s proven prompt shape, then through `TextQuality.sanitizeLabel`. **No new
`LLMProvider` method, no `GenerationSchema`, no indices** — the first draft's machinery existed only
to constrain `kind` and `parent`, which are no longer model outputs.

**Any other language → deterministic word-boundary shortening**, never the model. The measurement is
unambiguous: the on-device model *translates* German input to English, once producing an outright
error (`die Bahn-Reklamation …` → "Train Advertisement Claim"; a *Reklamation* is a complaint), and
a "same language, do not translate" instruction **does not fix it** — the model either ignores it or
emits broken German ("Später Zuganzeige Einreichen"). Translating also violates the project rule
that node names are content and are never localized.

**Routing** uses `NLLanguageRecognizer` (first-party, on-device, pure): 11/11 correct in the probe,
confidence ≥0.92 on every multi-word input. Ambiguous or undetected → treat as non-English and take
the deterministic path, so the fallback is the safe default rather than the model.

**The deterministic path is good, not a consolation.** Quick-add sentences are usually already
inside the 60-char cap — nine of eleven probe inputs were — so the shortening returns them whole, in
the user's own words, guaranteed correct. Only very long input truncates awkwardly, which is the
known and accepted cost.

**Therefore the name is never empty**, so a provider failure never leaves `Save` disabled: any
model failure (no provider, throw, empty output, gate rejection) falls through to the same
deterministic shortening. The unit returns `nil` only for empty input.

`Sendable`, so the `@MainActor` app can await it off-main.

### 3. `description` becomes writable

`NodeFields` grows `description`, and `NodeCommands.update` writes it. **The update path needs a
test that an unedited description is not blanked** — today's contract is "leaves description
untouched", so widening it is exactly where a regression would hide.

## App changes

The modal (`NodeEditor`) grows **two** fields — not the three the first draft implied, since the
parent picker is deferred with parenting itself:

1. **"Describe it"** — the input. Submitting it requests a label.
2. **Description** — editable, bound through to `NodeCommands.add`/`update`. Independently valuable:
   it closes the `description: ""` gap outright.

**Submitting must not collide with `Save`.** `Save` already owns `.defaultAction`, so a bare Return
inside the prompt field has two claimants — masked today only because `Save` is disabled while the
name is empty, and unmasked the moment a name exists. The prompt field therefore gets an **explicit
affordance** (a "Suggest" button, or ⌘↩), and the plan must state the chosen one. There is no
`onSubmit`-inside-a-sheet precedent in this codebase to copy.

**Parent defaults to the current selection** instead of `nil`. A one-line change to the two fast
paths, worth having on its own: today ⌘N from a project you are reading creates at top level.

**Filling fields by hand stays exactly as fast as today** — the prompt field is additive, never
required, and never blocks `Save`.

### Progressive fill, and the clobber rule

The proposal is user-triggered and writes into `@State` **the user may be editing concurrently** —
unlike slice 3a's narration, which keyed a `.task` on identity and wrote read-only display state. So
the closer precedent is `AppModel.runSearch` (`AppModel+Search.swift:73-121`): cancel any prior task,
a monotonic token, pre-`Task` locals, and a token re-check before assigning.

**The clobber rule, stated because it is otherwise undefined:** a returned label fills `Name`
**only if the user has not edited `Name` since submitting.** The task is held in `@State` and
cancelled on dismiss.

### Failure is lossless, and the modal stays committable

Provider unavailable, a throw, an empty response, or a gate rejection all fall through to the
**deterministic shortening** — the same path non-English input takes. The typed sentence is already
in `Description` verbatim, and `Name` holds a correct-by-construction label from the user's own
words. Nothing is lost, no alert fires, and `Save` is never stuck disabled.

This is a change from the first draft, which left `Name` empty on failure and so ran into
`Save`'s `.disabled` guard (`NodeOrganizing.swift:65`) — a review finding. Having a deterministic
path for language reasons removes the failure-path problem for free.

**Not gated by the Settings ▸ Intelligence narration toggle** — that governs narration, and reusing
it would make one control mean two things. A dedicated toggle is YAGNI until asked for.

### Write path

`AppModel.commitNewNode` → `NodeCommands.add`, now passing a real `description`. Settings v2's
refusal-versus-failure classification (`AppError` → `presentedError` → the single `RootView` alert)
already covers it; no new error surface.

## Three interactions that need an explicit decision

1. **`NodeDescriber.describe(force: true)` overwrites a description.** Reachable from a DetailView
   action (`AppModel+Narration.swift:91`); `nodes.description` carries no provenance flag, so a
   user-typed description is byte-indistinguishable from a model-authored one. **Accepted as-is:**
   the action's entire purpose is to re-derive, and it is explicit. Recorded so it is a decision
   rather than a surprise; a `descriptionAuthored` marker in `metadataJSON` is the fix if it bites.
2. **Eval registration.** `CLAUDE.md` requires a new model-backed task to register an `EvalTask`.
   This task is the *same shape* as `nameStrand`, which **is not registered** — so registering only
   this one would leave the older, higher-volume path uncovered while implying naming is measured.
   **Proposed:** do not register a bespoke task here; log the pre-existing naming-coverage gap in
   `backlog.md` as its own item covering **both** call sites. Reviewer evidence: a new task needs a
   fourth `CorpusItem` case plus DTO, exhaustive-switch updates, **two hardcoded task lists in
   `CorpusBuilder` that the registry↔config test does not check** (so a task can register, pass the
   suite, and silently load zero corpus items), and a gold set that cannot live in gitignored
   `.eval/`. **This is the one place the spec proposes not following a stated project rule, so it
   needs the user's ruling.**
3. **Focus scoping** is not applicable here (no candidate retrieval), but the deferred parenting
   increment must pass `visibleNodeIDs` like every other surface, or a Work Focus could be offered a
   Personal parent.

## Localization

New chrome strings in `Localizable.xcstrings`, en + de, authored by hand against the Swift literals
(`xcodebuild` does not populate the catalog — IDE-only). The **name and description are captured
content and are never localized**.

## Testing

**Kit carries the weight** (the app target has no unit tests):

- `TextQuality.sanitizeLabel` after the move: existing strand-name cases still pass; ≤60-char cap;
  multi-sentence rejection; list-marker and quote stripping.
- The deterministic shortening: input already ≤ cap returns whole; longer input breaks on a **word**
  boundary, never mid-word; a single word longer than the cap still yields something; empty → `nil`.
- `NodeLabeler` routing: German input **never calls the provider** (assert with a provider double
  that fails the test if invoked); English input does; a provider throw still yields the
  deterministic label rather than `nil`.
- `NodeCommands.update` writes a description **and** leaves an unedited one intact.
- `NodeCommands.add` persists a description end-to-end.
- `NodeFields` gaining a member breaks no existing caller.

**App:** `xcodebuild` build plus a non-blocking smoke-launch of the inner binary with throwaway
`PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`, then the carries below.

### Human-verify carries (built app at `/Applications`, real store)

- A typed **English** sentence yields a readable label; the sentence itself is the description.
- A typed **German** sentence yields a **German** name — never an English translation.
- Editing `Name` while the suggestion is in flight — your text survives (the clobber rule).
- Provider unavailable (select cloud with no key): sentence in Description, no error, `Save`
  enabled once a name is typed.
- ⌘N while a project is selected creates **under it**, not at top level.
- Submitting the prompt field does not accidentally trigger `Save`.
- `pensieve list` shows the node where the app said it would.
- German in situ (`-AppleLanguages '(de)'`).

## Out of scope

- **Stage 2** — conversational agent, organizing verbs by instruction, grounded Q&A.
- **Icon / colour / context inference** — defaults and pickers exist.
- **Bulk creation** from a multi-sentence paste.
- **Rewriting the description.** It is the user's words; the model never sees them for editing.

## Deferred, with triggers

- **Model-assisted parenting.** *Trigger: a committed measurement.* Write 15–20 quick-add sentences
  as a gold set, score three rankers against the live index — the shipped AND expression, OR
  aggregated by owning node across all hit kinds, and an idf-weighted token overlap over the 281
  `name — description` strings — and report recall@8 of the parent you would have picked. Commit the
  probe under `docs/superpowers/measurements/`, as the retrieval work established. Only then decide
  whether a candidate list and a parent picker earn their place. **Note two mechanical findings for
  that work:** `SearchQueries.search` has **no kind filter** (so "top 8 node hits" needs a new
  `kinds:` predicate or a large over-fetch), and BM25 length-normalisation systematically favours
  short-named strands over the projects they belong to.
- **A parent picker in the modal.** Deferred with parenting. `New Child…` already passes the right
  parent and `Move to…` fixes mistakes, so the selection default covers the common case.
- **Eval coverage for naming**, across both `nameStrand` and this path (item 2 above).

## Risks

- **On-device label quality is measured and good** for English (21/21 gated, 16/16 usable) — see
  `measurements/2026-08-13-slice5-label-quality/`. Two residual notes: the model sometimes drops the
  distinguishing term (`loose end resolution verbs` → "CLI Migration"), and the gate rejected
  **0 of 21**, so `isTerseLabel` is tail insurance here rather than a working filter. Neither
  changes the design; both are reasons the field stays editable.
- **The German failure is non-deterministic**, which is why routing beats prompting. The same input
  produced a wrong label on one run and a correct one on another, so this class of error will not
  reliably appear in testing and cannot be prompted away.
- **The slice's success criterion narrows.** The three-pane spec says "correctly-typed, sensibly
  parented"; here "sensibly parented" means *the selection*, and correctness of kind is derived
  rather than judged. Both are defensible on the 281/281 measurement, but the narrowing is
  deliberate and recorded.
- **`NodeFields` and `NodeCommands.update` are public Kit API** with CLI callers. Widening them is
  the change most likely to have a caller the plan overlooks.

## What the reviews changed

Two independent Opus reviews of the first draft, both verified against the code, both returning **not
sound enough to plan from** — and converging on the same critical finding. Reproduced independently
before folding in. What they overturned:

- **The parent-suggestion mechanism retrieves zero rows** (both reviewers, measured; reproduced
  here). The first draft mis-filed this as a graded recall risk. The design lost a third of itself.
- **"Pensieve's first LLM write path into the canonical store" was false** — `nameStrand` predates it,
  and carries the `sanitizeStrandName`/`isTerseLabel` machinery the draft reinvented.
- **`kindIndex` carried zero information** — 281 of 281 nodes match `defaultKind(under:)`.
- **The invariant was unenforced on `name`**, its only generative field. One reviewer proposed
  enforcing token-containment via `FindMatcher`; **rejected** — "background sync stopped spawning" →
  "Background sync spawn failure" is the better label and containment would reject it. The gate is
  `isTerseLabel`, and the safety property is now worded honestly instead.
- **"Write path unchanged" was wrong** — `NodeFields` has no `description` and `update` refuses to
  write one.
- **Return-versus-`.defaultAction`**, the **clobber race** against user edits, and the stale
  sequencing note (that branch merged mid-review) were all real and are fixed above.

## What the pre-build spike changed

One reviewer recommended measuring on-device label quality before committing to any of the
machinery, since it is now the whole model contribution. Run before writing the plan; probes and
full results committed under `measurements/2026-08-13-slice5-label-quality/`.

It confirmed the English path and **found a defect the design would otherwise have shipped**: the
model translates non-English input, once producing a wrong label, and no prompt instruction fixes
it. That turned naming from one path into two, routed by `NLLanguageRecognizer` — and the
deterministic arm then closed the failure-path finding for free, because a name that is never empty
is a `Save` button that is never disabled.
