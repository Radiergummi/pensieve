# Talk to the system, stage 1 — describe a strand, get a strand (three-pane slice 5)

**Date:** 2026-08-13
**Status:** design approved, plan not yet written
**Slice:** Track A / three-pane app, slice 5 of 6 (`specs/2026-07-05-pensieve-app-three-pane-design.md:170`)
**Backlog entry:** "App: capture & instruct by talking to the system" (`backlog.md:1291`)

## Purpose

Type a sentence describing a thing you are about to work on; get a correctly-named,
correctly-typed, sensibly-parented node. The lightweight counterpart to auto-birth from ≥2
captured events — that path waits for evidence, this one starts from intent.

This is **stage 1 only**. Stage 2 (an embedded conversational agent driving organizing verbs
and grounded Q&A) stays deferred to its own spec, unchanged by this document.

## Why this needs a design rather than a patch

**This is Pensieve's first LLM write path into the canonical store.** Every shipped model call is
read-only in effect: extraction *proposes* loose ends that a verbatim gate then disposes of;
narration returns best-effort prose or `nil`; `NodeDescriber` writes a description but only for a
node that already exists, derived from local git signals rather than model invention.

Here, model output determines a row's identity — its name, its type, and its place in the tree the
whole app renders. That is a new interface, so it gets an invariant rather than a prompt.

## What already exists (verified in the tree, 2026-08-13)

- **`LLMProvider`** (`Sources/PensieveKit/LLM/LLMProvider.swift`) has exactly one required method,
  `complete`. Three structured methods layer on top as protocol extensions that decode JSON from
  `complete`; `FoundationModelsProvider` overrides each with guided generation. Adding a fourth
  structured method is the established shape, and costs the cloud and `claude -p` providers nothing.
- **Guided generation uses runtime `GenerationSchema`**, deliberately not the `@Generable` macro
  (whose plugin fails to load in this machine's test build — see the comment at
  `FoundationModelsProvider.swift:8-15`). Every existing call site uses only object, array, `String`
  and `Int` schemas. **No call site uses `anyOf`**, so string-enum constraint is unproven here.
- **Two classifiers already return indices** (`classifyGenuineIndices`,
  `classifyNonSalientIndices`) and are proven reliable on-device. This is the pattern to copy.
- **The on-device context window is small and real.** `LooseEndExtractor` chunks at a 2,500-char
  budget and recursively re-splits on an `exceededContextWindowSize` error
  (`LooseEndExtractor.swift:55-72`).
- **BM25/FTS5 is the only retrieval path** (`SearchIndexStore`, `FTSQueryBuilder`), indexing node
  names and descriptions among other content. Raw input never reaches `MATCH`.
- **`NodeCommands.add`** (`Sources/PensieveKit/Query/NodeCommands.swift`) already takes
  `name`/`kind`/`parent`/`description` and resolves the parent by UUID or name inside its write
  transaction. It needs no change.
- **The New/Edit modal** (`Sources/PensieveApp/NodeOrganizing.swift:9`) edits name, kind, context,
  colour and icon. It has **no description field and no parent picker**;
  `AppModel+Organizing.swift:166` passes `description: ""` unconditionally, and the parent is fixed
  by the call site via `NodeEditRequest.mode = .new(parent:)`. **So the app cannot set a
  description at all today.**

### Measured facts that shaped the design

Read from the live store (`pensieve.sqlite`, read-only) on 2026-08-13:

| Fact | Value | Consequence |
|---|---|---|
| Nodes | 281 (280 active, 1 archived) | The tree cannot go in the prompt |
| Kinds in use | `project` 182, `strand` 99 | `domain`, `concept`, `initiative`, `task`, `topic` have **zero** rows |
| Extraction chunk budget | 2,500 chars | 281 names ≈ 3× that, before any instruction text |
| BM25 on short queries | ≈2/8 (P3 measurements) | A single top-hit parent guess would often be wrong |

The last row is the load-bearing one. `backlog.md:510` records that short paraphrase queries are
BM25's documented weak spot — and a quick-add sentence is exactly that shape. Any design that lets
retrieval alone choose the parent is building on a signal this project has already measured as weak.

## The invariant

> **The model may only select or shorten. It never authors.**

Applied to the four fields of the **node that gets created** (not to the proposal type, which is
narrower — see `NodeProposal` below):

| Field | Origin | Can the model invent it? |
|---|---|---|
| `description` | the user's typed text, **verbatim** | No — copied, never generated |
| `name` | **shortened** from the user's text | No — only compressed |
| `kind` | an index into a list the caller presents | No — an unknown index is no suggestion |
| `parent` | an index into BM25-retrieved candidates | No — structurally impossible |

Two properties follow, and both are checkable in review rather than by inspection of a prompt:

1. **No fabricated identity can reach the store.** `kind` and `parent` are *choices among real
   options*, resolved by the caller. A model returning index 47 of 8 candidates produces a rejected
   proposal, not a bogus row.
2. **The trust gate is not involved, and does not need to be.** `description` is the user's own
   words, unmodified. `name` is those words compressed. `backlog.md:1314-1317` already settled this:
   user-authored metadata sits outside the cited gate, like `rename`. The gate governs claims about
   *captured* text; nothing here makes such a claim.

**Not touched:** `TranscriptVocabulary.injectionMarkers`, `TranscriptParser.isInjectedOrCommand`,
`isUserPrompt`, `LooseEndVerifier`, or any extraction path. This feature neither reads nor writes
them.

## Kit units

All in PensieveKit, all tested, pure where the work allows.

### `NodeProposal`

The value crossing the seam. Deliberately holds **indices, not identifiers**:

```
struct NodeProposal: Sendable, Equatable {
  var name: String
  var kindIndex: Int
  var parentIndex: Int
}
```

`description` is absent on purpose: it is the user's input, so the caller already has it and the
model is never asked for it. A field the model cannot influence should not be in the model's
output type — that is the invariant expressed in the type rather than in a comment.

**"Top level" is an explicit numbered choice**, not a sentinel. The candidate list always ends with
a `[n] (no suitable parent — top level)` entry, so the model can say "none of these" *in range*.
That removes the need for a `-1` magic value and makes every legal answer a valid index, which in
turn makes the out-of-range rule below unambiguous.

### `NodeProposer`

The unit that owns the whole flow. Given the typed text and a database:

1. **Gather candidates.** Query the shipped BM25 index with the typed text and take the top ~8
   **node** hits, discarding loose-end and event hits. Archived excluded. *(An event hit's owning
   node is arguably also a parent signal — a commit matching "sync agent" implies its repo's node.
   Deliberately not folded in for v1: it is the obvious first enrichment if suggestions prove weak,
   and it pairs with the recall risk noted at the end.)*
2. **Build the prompt.** The typed text, a numbered candidate list (`[0] Pensieve — the …`), and a
   numbered kind list. Bounded by construction: 8 candidate names plus 2 kind labels sits far
   inside the 2,500-char budget that extraction proved workable, with no chunking needed.
3. **Resolve.** Map `kindIndex`/`parentIndex` back to a real `NodeKind` and `UUID?`. **An
   out-of-range index means "no suggestion for that field"** — that field keeps the modal's
   existing default (the caller's parent, the modal's default kind), and the rest of the proposal
   still stands. Explicitly *not* clamped to the nearest valid index, which would turn a confused
   model into a confident wrong answer; and explicitly *not* grounds for discarding the whole
   proposal, since a good name with a bad parent index is still worth showing.
4. **Return `nil` on any failure.** No provider, a throw, an empty name, an unparseable response:
   all one outcome. `SummaryBuilder.narrate` is the precedent — best-effort units return `nil`, and
   never a plausible-looking fallback.

**Kind list contents — a decision.** Present only `project` and `strand`. The other five kinds have
zero rows in 281 nodes, so offering seven options spends scarce on-device context on choices the
user has never once made, and invites a confidently-wrong `topic`. `retype` already exists if a
kind needs changing, and widening the list later is a one-line change.

**Empty-retrieval fallback.** When BM25 returns no candidates, the candidate list is empty and
`parentIndex` resolves to the caller's default — the currently selected node, or top level. The
model is not asked to choose from an empty set.

### The provider seam

One new method, following the established pattern exactly:

```
func proposeNode(prompt: String) async throws -> NodeProposal?
```

- **Default (protocol extension):** decode JSON from `complete`, as the other three do. This is
  what `claude -p` and the cloud providers get for free.
- **`FoundationModelsProvider` override:** a runtime `GenerationSchema` with `name: String`,
  `kindIndex: Int`, `parentIndex: Int`. All three are types the existing schemas already use, so
  **no unproven API** — this is why the design returns indices rather than UUID strings constrained
  by `anyOf`.

### Eval registration

`CLAUDE.md` requires that a new LLM-backed task register an `EvalTask` and take its default model
from `pensieve eval` rather than a hand-picked constant, enforced by a `registry ↔ config` test.
So: a `NodeProposalTask` in `Sources/PensieveKit/Eval/`, modelled on `DescriptionTask` — the right
precedent, since description is likewise best-effort and outside the cited gate.

Scoring is judged output, not exact match: does the name read as a label for the input, is the kind
plausible, is the parent the one a human would pick. The gold set is small and hand-written; this
is a quality signal for model *selection*, not a precision gate like extraction's.

## App surface

### The modal grows three things

`NodeEditor` (`NodeOrganizing.swift`) gains:

1. **"Describe it"** — a text field at the top. Return fires the proposal.
2. **Description** — a real editable field, bound through to `NodeCommands.add`. Independently
   valuable: it closes the gap at `AppModel+Organizing.swift:166` where the app can never set a
   description.
3. **Parent picker** — reuses `MovePicker`'s list-building, but **simpler**: a node being created
   has no descendants, so the `NodeForest.descendantIDs` guard `Move to…` needs does not apply.
   Every existing node is a legal parent. Defaults to the request's parent (today's behaviour) or
   the proposal's pick.

### Behaviour

Progressive, matching slice 3a's narration state machine: return starts the proposal, the fields
below show a brief in-place spinner, then populate. Everything stays editable throughout, and
**`Create` is never blocked or gated on the model.** Cancel/Escape writes nothing. Filling the
fields by hand and ignoring the prompt field entirely must remain exactly as fast as it is today.

The proposal runs off the main actor (`NodeProposer` is `Sendable`, as `SummaryBuilder` is) and its
task is cancelled on dismiss.

### Failure is silent and lossless

Provider unavailable, a throw, or `nil`: the typed sentence drops into **Description verbatim** and
`Name` stays empty. That is precisely today's modal plus the user's text — nothing is lost, nothing
must be retyped, and no alert fires. This is a best-effort feature and `narrate` is the precedent.

**Not gated by the Settings ▸ Intelligence narration toggle** — that toggle governs narration, and
reusing it would make one control mean two things. A dedicated toggle is YAGNI until asked for.

### Write path

Unchanged. `AppModel.commitNewNode` → `NodeCommands.add`, now passing a real `description` and a
user-confirmed `parent` instead of `""` and the call site's fixed value. Settings v2's
refusal-versus-failure classification (`AppError` → `presentedError` → the single `RootView` alert)
already covers the write, so this adds no error surface.

### Provider selection and what leaves the machine — an explicit decision

With a cloud provider configured, the prompt carries the user's typed sentence **and up to ~8 node
names**. Narration already sends event summaries under the same setting, so honouring the selected
provider is consistent — and it is recorded here as a decision rather than left as an accident.

**Extraction remains on-device unconditionally.** This feature is not extraction and does not
change that guarantee.

## Localization

New chrome strings in `Localizable.xcstrings`, en + de, authored by hand against the Swift literals
(`xcodebuild` does not populate the catalog — IDE-only). The node's **name and description are
captured content and are never localized**, consistent with every other content surface. The
default new-node name likewise stays unlocalized, as slice 4 established.

## Testing

**Kit carries the weight** (the app target has no unit tests):

- `description` survives verbatim — including leading/trailing whitespace behaviour, newlines, and
  text that looks like JSON or a code fence.
- `kindIndex`/`parentIndex` resolve to the right `NodeKind`/`UUID`.
- **An out-of-range index (negative or past-the-end) falls back to that field's default and leaves
  the rest of the proposal intact** — asserted for both fields independently, and asserted *not* to
  clamp to the nearest valid index.
- The explicit top-level choice resolves to `parent == nil`, distinctly from an out-of-range index.
- `nil` on: no provider, provider throws, empty name, unparseable response.
- Candidate retrieval returns real nodes from the FTS5 index, discards non-node hits, excludes
  archived, and respects the ~8 cap.
- Empty retrieval yields a candidate list holding only the top-level choice, and the caller's
  default parent.
- The `registry ↔ config` eval test passes with `NodeProposalTask` registered.

**App:** `xcodebuild` build plus a non-blocking smoke-launch of the inner binary with throwaway
`PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`, then human-verify carries (below).

### Human-verify carries (need the built app at `/Applications` and the real store)

- A typed sentence about work on an existing project proposes **that project** as parent.
- A sentence about something genuinely new proposes top level rather than a forced bad parent.
- Hand-filling every field without touching the prompt field is unchanged from today.
- With the provider unavailable (select a cloud provider with no key), the typed text lands in
  Description and nothing errors.
- `pensieve list` shows the created node where the app said it would.
- German in situ (`-AppleLanguages '(de)'`), including the new field labels.

## Out of scope

- **Stage 2** — a conversational agent, organizing verbs by instruction ("nest auth under
  platform"), grounded Q&A. Its own spec, deliberately deferred.
- **Editing an existing node's description via the prompt field.** The prompt field is
  creation-only; the new Description field is editable on both paths, which is enough.
- **Icon/colour/context inference.** The model proposes identity and placement only. These have
  defaults and a picker already.
- **Bulk creation** from a multi-sentence paste.

## Risks and open concerns

- **On-device name quality is unmeasured.** A ~3B model shortening a sentence into a label may
  produce something flat ("Sync agent"). Mitigated by the eval task choosing the model and by every
  field being editable before write — but it is the most likely source of "this is not useful
  enough" and the eval gold set should be written with that question in mind.
- **BM25 recall@8 on short queries is assumed, not measured.** P3 measured P@1 (≈2/8); recall@8
  should be materially better, but this design leans on it. If parent suggestions prove poor, the
  cheap remedy is widening the candidate set before touching the prompt — and the honest fallback
  is the current selection, which costs nothing.
- **The modal is getting busy.** It already carries two zones (form plus icon preview); this adds
  two fields and a picker. If it reads as cluttered, the split to consider is prompt-first (a small
  sheet that proposes, then hands off to the existing modal) — deliberately *not* chosen now, since
  it doubles the surface for a benefit that only materialises if crowding actually bites.
- **Sequencing.** `NodeOrganizing.swift` and `AppModel+Organizing.swift` are both modified by the
  in-flight `worktree-loose-end-resolution` branch. This spec is conflict-free; the **plan should be
  written after that branch merges**, or expect a small rebase.

## Verification of success

A typed description produces a correctly-typed, sensibly-parented node — the slice's own criterion
at `specs/2026-07-05-pensieve-app-three-pane-design.md:170` — and a dead provider leaves the modal
exactly as useful as it is today.
