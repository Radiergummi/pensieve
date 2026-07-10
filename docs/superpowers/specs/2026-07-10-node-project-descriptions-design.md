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
domain), derived from files the repo already carries (README, CLAUDE.md, package manifest). The
daemon's auto pass runs through the on-device provider by default; the app's manual refresh reuses
whatever provider is configured (which may be cloud, exactly like "Last Work Done" narration —
see Trust boundary). Keep the derivation source-agnostic where it's cheap to, so other source types
can feed the same prompt later — without building an abstraction for a single current contributor.

## Non-goals (YAGNI)

- No per-source-kind describer protocol / abstraction — git is the only contributor for now; the
  general seam is the shared prompt over gathered signals, not a plugin system.
- No content-hash change detection / auto-refresh on file edits — auto derivation is
  retry-until-non-empty (a non-empty `description` *is* the terminal state; no separate marker);
  the user re-derives manually when they want a fresh pass.
- No `descriptionInferred` metadata marker (an earlier draft had one). Diverges deliberately from
  `refineProjectNames`, which marks once and stops — the user chose "attempt on each drain until a
  description exists," so the empty `description` field itself is the retry condition.
- No description for Claude-only nodes or other kinds (deferred).
- No change to the strict cited trust gate. Descriptions are best-effort, *outside* the gate —
  exactly like strand naming and "Last Work Done" narration. Loose ends stay cited.

## What already exists (reuse, don't rebuild)

- `Node.description: String` — the column, already rendered in `DetailView`'s "What It Is" section
  (shown only when non-empty).
- `ProjectContext.gather(commonDir:)` — already reads README (case-insensitive text variants),
  CLAUDE.md, the first package manifest (`package.json` / `composer.json` / `Package.swift` /
  `Cargo.toml` / `pyproject.toml`), and the git remote. Currently feeds only `namePrompt(_:)`.
- The per-pass cap pattern (`nameRefineCap`) — mirrored (`descriptionRefineCap`). The `nameInferred`
  marker pattern is *noted but intentionally not reused* (see Non-goals — descriptions retry until
  filled, so `description.isEmpty` is the terminal check, not a marker).
- `refineProjectNames()` is called from **`SyncRunner.run()` (SyncRunner.swift:41)**, after
  `ingester.drain()` — *not* inside `drain()`, and *not* on the `pensieve ingest` path. This is the
  precedent the new pass follows.
- The app configures an LLM provider via `makeDefaultLLMProvider`, but currently retains only the
  wrapping `SummaryBuilder` (its `provider` is `private`) — the raw provider is a throwaway `let`
  inside `rebuildSummaryBuilder()` (AppModel.swift:164). The manual refresh needs the raw provider,
  so AppModel must retain it (see App).

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

The result type distinguishes the three outcomes the caller and cap logic need:

```
enum DescribeOutcome { case wrote, attemptedEmpty, noSignal, ineligible }
```

Steps:
1. Load the node; require kind == `project` with exactly one `gitRepo` source (else `.ineligible`).
2. `ProjectContext.gather(commonDir: sourceKey)`.
3. Require a **meaningful signal** — not mere file presence, but *substance*: a manifest description,
   OR a README/CLAUDE.md excerpt whose trimmed body exceeds a small threshold (e.g. > ~40 chars past
   its title line). A bare dir name, a bare remote, or a one-line `# foo` README is **not** enough.
   If no meaningful signal → `.noSignal` **without any write and without invoking the LLM** (so a
   fleshed-out README later triggers a retry, cheaply, and without burning an LLM call). `force`
   does not override this — there is nothing to describe from.
4. `provider.complete(prompt: ProjectContext.describePrompt(ctx))`, then sanitize.
5. Non-empty sanitized result → write `description`, return `.wrote`. Empty result → write nothing,
   return `.attemptedEmpty`. **No metadata is written in any branch** — a non-empty `description`
   is itself the terminal "done" state.

`force` only matters at the eligibility gate for a node that *already has* a non-empty description:
the auto pass never selects it (see below), but the manual button passes `force: true` to re-derive
and overwrite it. (`force` never bypasses the exactly-one-git-source or meaningful-signal guards.)

**Sanitizer** — a pure, tested helper (paralleling `sanitizeStrandName`): trim; strip a leading
list marker / surrounding quotes / code fences; collapse to at most ~2 sentences; return nil for
empty. Keeps the output from reading like a bulleted list or echoing the prompt.

**3. `Ingester.describeProjectNodes()`** — a best-effort pass parallel to `refineProjectNames()`,
**wired into `SyncRunner.run()` alongside `refineProjectNames()`** (after `drain()`), *not* into
`drain()` and *not* the `pensieve ingest` path. `guard let llm else { return }` is a belt-and-braces
no-op, but the real reason it never runs in the app is that the app never calls `SyncRunner`. So it
runs on the launchd sync daemon (`pensieve sync`), on-device.

Candidate selection (read-only scan): kind == `project`, exactly one `gitRepo` source,
`description.isEmpty`. **No marker check** — the empty description *is* the filter.

The `descriptionRefineCap` (e.g. 20) bounds **actual LLM invocations**, not candidates: iterate
candidates calling `NodeDescriber.describe(force: false)`; a `.noSignal` result is free (no LLM) and
does **not** consume a cap slot; stop once `.wrote`/`.attemptedEmpty` outcomes reach the cap, leaving
the rest for the next cycle. This prevents signal-less repos (a fresh repo, a docs-free repo, a node
whose git key no longer exists on disk) from starving repos that *do* have describable content.

**Retry-until-non-empty** falls out of the empty-description filter + the substance gate:

| Situation | Outcome |
|---|---|
| Repo has no README/CLAUDE.md/manifest, or only a thin `# foo` README | `.noSignal` → no LLM call, no write, no cap slot → retried cheaply each cycle until real content appears |
| Repo has substantive content, LLM yields a description | `description` written (`.wrote`) → no longer `description.isEmpty` → dropped from candidates, never auto-retried |
| Repo has substantive content, LLM returns empty (rare) | `.attemptedEmpty` → still `description.isEmpty` → retried next cycle (consumes a cap slot); this is the user's chosen "retry until non-empty" |
| Description already non-empty | Not a candidate (auto pass skips it); only the manual `force: true` button re-derives |

**Known cost (accepted):** a repo that permanently keeps substantive-but-unsummarizable content
would re-invoke the LLM each daemon cycle. The substance gate makes this rare (thin READMEs are
`.noSignal`, free), it's bounded per-cycle by the cap, and `.wrote` candidates self-drain out of the
set over cycles — leaving only genuine retriers. This matches the user's explicit "attempt on each
drain" choice; content-hash suppression is a deferred Non-goal.

### App

**`DetailView` "What It Is"** gains a small refresh affordance beside the description, mirroring the
existing progressive narration pattern:

- **Description present:** render it (as today) + a small `arrow.clockwise` button beside the
  heading to re-derive on demand (`force: true`).
- **Empty but node has exactly one `gitRepo` source:** show a subtle "Generate description" button.
  The one-git-source check is a cheap DB read the detail load already can carry (a `hasGitSource`
  flag alongside the node), so the button only appears where `NodeDescriber` can actually act — no
  button that silently no-ops on a Claude-only or multi-repo (merged) node.
- **While running:** a small `ProgressView`, gated on `loadedNodeID == node.id` (same stale/wrong-node
  guard the narration state machine uses; the refresh state resets on node change identically).
- **Empty and no eligible git source:** show nothing (unchanged).
- **`force` refresh yields nothing** (`.attemptedEmpty` / `.noSignal`): leave the existing text as-is
  and surface a brief inline "Nothing to summarize" note rather than a silent no-op.

**Provider retention** — `AppModel` currently keeps only `summaryBuilder` (private provider). Add a
retained raw provider rebuilt in `rebuildSummaryBuilder()` (same `makeDefaultLLMProvider(...)` call
that already builds the summary provider), so `describeNode` has something to pass. No new provider
construction path — it reuses the one already resolved for narration.

**`AppModel.describeNode(_:)`** — calls `NodeDescriber.describe(force: true)` off-main with the
retained provider, then `refresh()` to reload the node. Best-effort: a failure or empty result
leaves the existing description untouched. (Node-only write; follows the existing explicit-`refresh()`
convention since it doesn't change the Event count. A concurrent daemon write to the same
`description` column is last-writer-wins on a single field — benign for a best-effort label, and
there is no longer any shared `metadataJSON` marker to clobber.)

**Localization** — the one or two new UI strings ("Generate description" and the refresh
button label / tooltip) get English + German String-Catalog keys, reconciled by hand (per the known
`xcstrings`-not-auto-populated gotcha). The description **content** is never localized — it is
canonical-store content (English-fallback), like node names and loose-end quotes.

## Testing

Pure / tested in PensieveKit — the risky logic (outcomes, eligibility, cap, substance gate) gets
direct coverage, not just the easy pure bits:
- `ProjectContext.describePrompt` — includes exactly the present signals, correct instruction shape.
- The description sanitizer — trims, strips list markers/quotes/fences, bounds sentence count,
  rejects empty.
- The **meaningful-signal substance predicate** — thin (`# foo`) README and bare-remote-only →
  no signal; a substantive README / manifest description → signal. Pure, no git needed.
- `NodeDescriber.describe` **outcomes** with an injected fake `LLMProvider` (a spy that records
  whether it was invoked) over a seeded canonical store: non-project / zero / two git sources →
  `.ineligible`; no-signal source → `.noSignal` **with the provider never invoked**; substantive
  signal + non-empty model output → `.wrote` (+ `description` written); substantive signal + empty
  output → `.attemptedEmpty` (nothing written, still `description.isEmpty`); `force: true` over an
  already-described node re-derives.
- `describeProjectNodes` candidate selection + cap: only `description.isEmpty` single-git-source
  project nodes are selected; `.noSignal` candidates consume no cap slot (a mix of signal-less and
  substantive nodes exceeding the cap still reaches the substantive ones).

The one place needing a temp git repo (real signal gathering through `ProjectContext.gather`)
follows the existing best-effort integration pattern the suite already uses.

App views stay thin — verified via `xcodebuild` build + a non-blocking smoke-launch of the inner
binary with throwaway `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB`.

## Trust boundary

Descriptions are best-effort and **outside** the strict cited trust gate — identical in status to
strand naming and "Last Work Done" narration. Extraction and loose ends remain grounded and cited;
this feature only fills an organizational label.

## Files (anticipated)

- `Sources/PensieveKit/Ingest/ProjectContext.swift` — add `describePrompt`.
- `Sources/PensieveKit/Intelligence/NodeDescriber.swift` — new shared unit (`DescribeOutcome`,
  `describe`, sanitizer, substance predicate). No metadata-marker helpers.
- `Sources/PensieveKit/Ingest/Ingester.swift` — `describeProjectNodes()` pass + `descriptionRefineCap`.
- `Sources/PensieveKit/Sync/SyncRunner.swift` — call `describeProjectNodes()` alongside
  `refineProjectNames()` (the actual wiring point; *not* `drain()`).
- `Sources/PensieveApp/DetailView.swift` — refresh affordance + progressive state + `hasGitSource` gate.
- `Sources/PensieveApp/AppModel.swift` — retained raw provider + `describeNode(_:)`.
- `Sources/PensieveApp/Localizable.xcstrings` — new UI keys (en + de).
- `Tests/PensieveKitTests/` — prompt, sanitizer, and describer tests.
