# Node project descriptions (README-derived "What It Is")

**Date:** 2026-07-10
**Status:** Approved (brainstorm) — ready for implementation plan
**Scope:** One focused feature. Populate the existing, currently-empty `Node.description` for
git-backed project nodes from local repo signals, plus an on-demand refresh button in the app.

## Problem

The app already displays a per-node **"Last Work Done"** LLM narration (recent activity) and a
**"What It Is"** header. "What It Is" renders `Node.description` — but for git *project* nodes that
field is almost always empty:

- **Strands** already get an activity-derived `description` (`Ingester.nameStrand`).
- **Git project nodes** get their *name* inferred from repo signals (`Ingester.refineProjectNames`),
  but their `description` is left blank.

So a project's card answers "what was I last doing here?" but not "what *is* this project?".

## Goal

Give git-backed project nodes a concise, grounded description of what the project **is** (purpose /
domain), derived on-device from files the repo already carries (README, CLAUDE.md, package
manifest). Keep the mechanism general so other source types can contribute descriptions later.

## Non-goals (YAGNI)

- No per-source-kind describer protocol / abstraction — git is the only contributor for now; the
  general seam is the shared prompt over gathered signals, not a plugin system.
- No content-hash change detection / auto-refresh on file edits — auto derivation is
  retry-until-non-empty, then stop; the user re-derives manually when they want a fresh pass.
- No description for Claude-only nodes or other kinds (deferred).
- No change to the strict cited trust gate. Descriptions are best-effort, *outside* the gate —
  exactly like strand naming and "Last Work Done" narration. Loose ends stay cited.

## What already exists (reuse, don't rebuild)

- `Node.description: String` — the column, already rendered in `DetailView`'s "What It Is" section
  (shown only when non-empty).
- `ProjectContext.gather(commonDir:)` — already reads README (case-insensitive text variants),
  CLAUDE.md, the first package manifest (`package.json` / `composer.json` / `Package.swift` /
  `Cargo.toml` / `pyproject.toml`), and the git remote. Currently feeds only `namePrompt(_:)`.
- The `nameInferred` marker pattern in `metadataJSON` (`nameInferred(inMetadata:)` /
  `settingNameInferred(in:)`) and the per-pass cap (`nameRefineCap`) — mirrored for descriptions.
- The app already holds a configured LLM provider (`makeDefaultLLMProvider`, via `summaryBuilder`).

## Design

### Kit

**1. `ProjectContext.describePrompt(_ ctx:) -> String`** — a new static sibling to the existing
`namePrompt(_:)`, over the *same* gathered signals (the "reuse gather + generic prompt" seam).
Instruction, roughly:

> Summarize what this project **is** in 1–2 sentences, from the signals below. Describe its
> purpose / domain — not recent activity or history. Output only the description as plain prose:
> no heading, bullets, quotes, or code fences. Prefer what the signals say; do not invent a
> purpose the signals do not support. If the signals are too thin to say anything, output nothing.

Built from the present signals only (dir name, remote, manifest, README excerpt, CLAUDE.md excerpt),
identical to how `namePrompt` composes its lines.

**2. `NodeDescriber`** — a small tested unit, the shared entry point for *both* callers:

```
NodeDescriber.describe(_ db: any DatabaseWriter,
                       nodeID: UUID,
                       provider: any LLMProvider,
                       force: Bool) async -> Bool
```

Steps:
1. Load the node; require it to have exactly one `gitRepo` source (else return `false`).
2. `ProjectContext.gather(commonDir: sourceKey)`.
3. Require at least one **meaningful signal** — README, CLAUDE.md, or manifest present (a bare
   directory name is not enough). If none, return `false` **without** setting the marker (so a
   README added later triggers a retry). `force` does not override this — there is nothing to
   describe from.
4. `provider.complete(prompt: ProjectContext.describePrompt(ctx))`, then sanitize.
5. If the sanitized description is non-empty: write `description` **and** set the
   `descriptionInferred` marker in `metadataJSON`; return `true`. Otherwise return `false`.

**Sanitizer** — a pure, tested helper (paralleling `sanitizeStrandName`): trim; strip a leading
list marker / surrounding quotes / code fences; collapse to at most ~2 sentences; return nil for
empty. Keeps the output from reading like a bulleted list or echoing the prompt.

**Marker helpers** — `descriptionInferred(inMetadata:)` / `settingDescriptionInferred(in:)`,
mirroring the `nameInferred` pair, preserving other metadata keys (`.sortedKeys`).

**3. `Ingester.describeProjectNodes()`** — a best-effort pass parallel to `refineProjectNames()`,
called from the same LLM-equipped drain point. `guard let llm else { return }` → **no-op in the
app's LLM-less drain**; runs in the daemon / CLI drain. Eligibility (read-only scan, then act):

- kind == `project`
- exactly one `gitRepo` source
- `description.isEmpty`
- **not** already marked `descriptionInferred`

For each candidate (capped by a `descriptionRefineCap`, e.g. 20), call
`NodeDescriber.describe(force: false)`.

**Retry-until-non-empty** falls out of the eligibility + marker rules:

| Situation | Outcome |
|---|---|
| Repo has no README/CLAUDE.md/manifest yet | No meaningful signal → skipped, **no marker** → retried on a later drain once a signal appears |
| Repo has a signal, LLM yields a description | `description` written + marker set → done, never auto-retried |
| User later *clears* the description | Marker is set → auto pass skips it (respects the clear); only the manual button re-derives |

### App

**`DetailView` "What It Is"** gains a small refresh affordance beside the description, mirroring the
existing progressive narration pattern:

- **Description present:** render it (as today) + a small `arrow.clockwise` button beside the
  heading to re-derive on demand (`force: true`).
- **Empty but node has a git source:** show a subtle "Generate description" button in place of the
  empty section.
- **While running:** a small `ProgressView`, gated on `loadedNodeID == node.id` (same stale/wrong-node
  guard the narration state machine already uses).
- **Empty and no git source:** show nothing (unchanged).

**`AppModel.describeNode(_:)`** — calls `NodeDescriber.describe(force: true)` off-main using the
app's already-configured provider, then `refresh()` to reload the node. Best-effort: a failure or
empty result leaves the existing description untouched. (Node-only write; follows the existing
explicit-`refresh()` convention since it doesn't change the Event count.)

**Localization** — the one or two new UI strings ("Generate description" and the refresh
button label / tooltip) get English + German String-Catalog keys, reconciled by hand (per the known
`xcstrings`-not-auto-populated gotcha). The description **content** is never localized — it is
canonical-store content (English-fallback), like node names and loose-end quotes.

## Testing

Pure / tested in PensieveKit:
- `ProjectContext.describePrompt` — includes exactly the present signals, correct instruction shape.
- The description sanitizer — trims, strips list markers/quotes/fences, bounds sentence count,
  rejects empty.
- `NodeDescriber.describe` eligibility & write behavior with an **injected fake `LLMProvider`** and a
  temp canonical store: no git source → `false`; meaningful-signal gathering exercised where
  feasible (git-signal reads follow the existing best-effort integration pattern, as
  `refineProjectNames` does).

App views stay thin — verified via `xcodebuild` build + a non-blocking smoke-launch of the inner
binary with throwaway `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB`.

## Trust boundary

Descriptions are best-effort and **outside** the strict cited trust gate — identical in status to
strand naming and "Last Work Done" narration. Extraction and loose ends remain grounded and cited;
this feature only fills an organizational label.

## Files (anticipated)

- `Sources/PensieveKit/Ingest/ProjectContext.swift` — add `describePrompt`.
- `Sources/PensieveKit/Intelligence/NodeDescriber.swift` — new shared unit + sanitizer + marker
  helpers (or marker helpers alongside the existing `nameInferred` pair in `Ingester`).
- `Sources/PensieveKit/Ingest/Ingester.swift` — `describeProjectNodes()` pass + `descriptionRefineCap`,
  wired into the same drain point as `refineProjectNames()`.
- `Sources/PensieveApp/DetailView.swift` — refresh affordance + progressive state.
- `Sources/PensieveApp/AppModel.swift` — `describeNode(_:)`.
- `Sources/PensieveApp/Localizable.xcstrings` — new UI keys (en + de).
- `Tests/PensieveKitTests/` — prompt, sanitizer, and describer tests.
