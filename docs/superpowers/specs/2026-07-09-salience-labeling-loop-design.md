# Salience labeling loop — design (Phase 1 of 2)

**Date:** 2026-07-09
**Status:** approved (brainstorm)
**Depends on:** the salience-eval finding (`docs/superpowers/salience-eval-2026-07-09.md`) — the
LLM salience gate is disabled; extraction is lossless again.
**Followed by:** Phase 2 — *train & gate* (on-device Create ML classifier + Core ML inference wired
into `ExtractionRunner` behind a recall-floor eval). Its own spec.

## Why

The merged LLM salience gate failed a hand-labeled eval on real data (on-device recall 0.68,
non-deterministic; `claude -p` Haiku 0.947/0.23). We disabled it. The durable replacement is a
**deterministic on-device Create ML classifier fed by human labels** — but a classifier needs a
labeled corpus, and there is currently **no way to label (or even clear) a loose end**: the
`LooseEnd.status` field (`"open"|"resolved"`) is never written by any UI or CLI path. Loose ends are
created by extraction and never actioned.

So Phase 1 builds the **labeling loop**: per-loose-end 👍/👎 that (a) fills the real UX gap — you can
finally act on loose ends — and (b) produces the human-labeled training corpus. It ships value on
its own even if the classifier never follows. No classifier, training, or gate is in Phase 1;
extraction stays lossless throughout.

## Goal & non-goals

**Goal:** let the user label each loose end **salient** (👍) or **noise** (👎) inline, everywhere loose
ends render; persist those labels in the canonical store as the ground-truth corpus; and support a
general **suggestion** mechanism so a machine (a one-off `claude -p` script now; the trained
classifier in Phase 2) can pre-fill guesses the user confirms with one glance — while training only
ever consumes **human-confirmed** labels.

**Non-goals (Phase 1):**
- **No classifier / training / inference / gate.** Extraction stays lossless (every verified loose
  end is surfaced). That is Phase 2.
- **No "done / resolve" lifecycle.** 👍 does **not** complete an item; resolution/follow-through is a
  separate later concern. `status` stays as-is.
- **No committed bootstrap feature.** The initial suggestion pass is a **throwaway, non-committed**
  script (like the eval sampler), not a CLI subcommand.
- **No bulk "accept all suggestions."** That would wholesale-adopt Haiku's low-precision guesses and
  defeat the audit. Every confirmed label is an individual human act.
- **The verbatim trust gate is untouched.** Labels are post-hoc metadata on already-verified,
  verbatim-cited loose ends; nothing about extraction or provenance changes.

## Decisions (from brainstorm)

1. **Taxonomy A — acting = labeling.** Two per-item actions: 👍 = *real loose end* (**positive**),
   👎 = *not a loose end* (**negative / noise**).
2. **👍 keeps the item open; 👎 removes it from the open list.** 👍 records a positive label but the
   item stays pending (it's real, not done). 👎 records a negative label and declutters it out of the
   open list (recoverable via undo). This lets genuine-but-unfinished loose ends become positive
   examples immediately — positives don't have to wait for completion.
3. **Two nullable columns, confirmed vs suggested.** `label` = the human-confirmed thumb; only the UI
   writes it. `labelSuggestion` = a machine guess; any suggester writes it. **Training reads `label`
   only.** `labelSuggestion` never enters the corpus — it only pre-highlights a thumb so the user
   confirms/flips a guess instead of deciding from scratch.
4. **The suggestion mechanism carries forward.** It is not throwaway plumbing: the one-off script
   fills `labelSuggestion` now; in Phase 2 the trained classifier writes its predictions there → the
   user confirms → the corpus grows → retrain. That is the standing active-learning loop.
5. **Labels live in the canonical store** (syncable via future CloudKit). A corpus of your labels is
   the crown jewel of this feature; it is not a device-local derived cache.
6. **Per-item buttons on the shared `LooseEndRow`**, so they appear on every surface at once.

## Architecture

### Layer map

| Concern | Where | Tested? |
|---|---|---|
| `label` / `labelSuggestion` columns (migration v11) | PensieveKit `Model/LooseEnd.swift`, `Store/CanonicalStore.swift` | schema test |
| `LooseEndLabel` string constants (`salient`/`noise`) | PensieveKit | pure |
| `LooseEndCommands` (confirm 👍/👎, clear, write suggestion) | PensieveKit | yes |
| "open loose end" query definition (exclude confirmed noise) | PensieveKit queries | yes |
| corpus read helper (confirmed labels for Phase 2) | PensieveKit | yes |
| 👍/👎 UI + suggestion pre-highlight + undo on `LooseEndRow` | PensieveApp (thin) | build + smoke |
| one-off Haiku suggestion pass | throwaway script (not committed) | n/a |

### Data model (migration v11, additive)

Add to `LooseEnd`:
- `label: String?` — `nil` (unlabeled) | `"salient"` | `"noise"`. **Human-confirmed** only.
- `labelSuggestion: String?` — `nil` | `"salient"` | `"noise"`. **Machine** guess (any suggester).

String constants in a `LooseEndLabel` enum/namespace (reuse pattern from `CaptureKind`/`SourceKind`;
never hardcode the strings). Both nullable → existing rows read `nil` (unlabeled), fully additive.

### "Open loose end" redefinition (consistency-critical)

Today an open loose end is `status == "open"`. It becomes:

> **open loose end = `status == "open"` AND `label != "noise"`**

i.e. confirmed-noise items drop out of the open set; 👍 (salient), unlabeled, and merely
*suggested*-noise items stay (a suggestion is not a decision — it must not hide an item before the
user confirms). This definition must be applied **consistently** at every open-loose-end read, or the
detail view and the menu-bar count will disagree. Known call sites to update to one shared predicate:
`LooseEndQueries`, `MonitorSnapshot`, `NextQueries`, `BriefingQueries`. (Folds in the long-standing
"shared per-node open-loose-end helper" carry.)

### Write commands (PensieveKit, tested)

`LooseEndCommands` (new, thin over the canonical store):
- `confirm(_ id: UUID, _ label: String)` — set `label` to `salient`/`noise` (human thumb).
- `clearLabel(_ id: UUID)` — reset `label` to `nil` (undo a mistaken thumb).
- `suggest(_ id: UUID, _ label: String)` — set `labelSuggestion` (used by the throwaway script and,
  in Phase 2, the classifier). Writing a suggestion never touches `label`.

These are the only writers of the two columns. `Ingester.drain()` stays the only writer of the rest
of a `LooseEnd`.

### Corpus read (for Phase 2)

A read helper returning `(quote, label)` for all `label != nil` rows — the confirmed training
corpus. Phase 2 consumes this; Phase 1 just makes it queryable and tested.

### App UI (thin, on `LooseEndRow`)

- Two icon buttons (`hand.thumbsup` / `hand.thumbsdown`) on each loose-end row.
- **State rendering:** a confirmed `label` shows its thumb **filled/active**; a `labelSuggestion`
  (no confirmed label yet) shows that thumb **pre-highlighted** (outline / tinted) — a visible "guess
  awaiting your confirm." Tapping a thumb writes the confirmed `label`; tapping the already-confirmed
  thumb again clears it.
- **👎 confirm** removes the row from the open list with a brief **undo** affordance (the write is
  `label = noise`; undo calls `clearLabel`). 👍 leaves the row in place, marked salient.
- Appears automatically on every surface that renders `LooseEndRow` (DetailView loose ends, the
  middle-list leaf loose ends, the ⌘⌥N recall window, smart-list detail).
- Writes go through `AppModel` → `LooseEndCommands` → explicit `refresh()`. Node-only/label-only
  writes must not trip the Event-count `ValueObservation` (match the existing slice-4 pattern).
- German localization for the accessibility labels and the undo text (the thumbs themselves are
  glyphs; loose-end content is never localized).

### One-off Haiku suggestion pass (throwaway, not committed)

To give the corpus a head start over the 587 open backlog without building a bootstrap feature: a
throwaway script (bash + `sqlite3` + `claude -p --model claude-haiku-4-5-20251001`, or a throwaway
Swift entry reusing `SalienceClassifier`) reads open loose ends, classifies in batches, and writes
`labelSuggestion` via the same column the UI reads. Back up the store first (additive write, but
still). The user then confirms/flips in-app. Not committed; documented at execution time.

## Error handling

- Label writes are best-effort but user-initiated: a failed write must surface (this pairs with the
  still-open "organizing-writes error surfacing" gap — at minimum, don't silently swallow). Phase 1
  can start with a simple error toast; full error-presentation is tracked separately.
- Migration is additive; existing rows read `nil` and behave exactly as today until labeled.

## Testing

- **Schema v11:** new columns nullable, default `nil`, round-trip.
- **`LooseEndCommands`:** confirm sets `label`; clear resets; suggest sets `labelSuggestion` without
  touching `label`; confirm overrides a prior suggestion's effect on filtering.
- **Open-loose-end predicate:** excludes `label == "noise"`; keeps `salient`, `nil`, and
  `labelSuggestion == "noise"` (suggestion alone never hides).
- **Corpus read:** returns only `label != nil` rows with the right `(quote, label)`.
- **App:** `xcodebuild` build + non-blocking smoke-launch (throwaway stores). Derivation stays in
  tested Kit; the view is thin.

## Open questions / risks

- **Backlog volume.** 587 open items is a lot to thumb through even pre-highlighted; the acceleration
  is skimming + correcting mislabels, not one-tap-per-item. Acceptable — you triage them anyway — and
  a future (Phase 2+) convenience could batch-confirm high-confidence *classifier* suggestions once
  the model is trusted (never Haiku's).
- **Class imbalance persists** (~16% salient); Phase 2 must handle it (class weighting / more
  positives via the loop). Out of scope here.
