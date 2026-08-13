# App UI verification harness — design

**Status:** approved in conversation 2026-08-13, plan not yet written.
**Predecessors:** none — this is the first automated signal over `Sources/PensieveApp/`.
**Related:** the slice-5 verification note in `CLAUDE.md` (the app smoke recipe exercises no app code);
the human-verify carry ledgers in `CONTINUE.md` accumulated by every app slice since 3a.

## Why

Every app slice since the three-pane work has ended the same way: a list of **human-verify carries** that
only the user can discharge, by launching the app, clicking through it, and reporting back. The ledger in
`CONTINUE.md` has never been empty. That is the slowest loop in this project, and it is slow for a
structural reason — there is no automated signal over the app target at all.

The two things that look like signals do not cover it:

1. **`make smoke` proves the embedded CLI launches** (`$(APP_CLI) --help`). That is real, but it is a
   statement about `Contents/Helpers/pensieve`, not about any view.
2. **The app-verification recipe documented in `CLAUDE.md`** — build, then background the inner Mach-O and
   kill it — was reproduced during the slice-5 review to **exercise no app code at all**: `AppModel.start()`
   runs from a `.task` on a rendered view body, and a backgrounded direct-exec never renders one. It also
   creates no store file. It has been passing while proving nothing, which is worse than having no check,
   because it reads as coverage.

So the app is verified by eyeball or not at all. That is why slice 5 shipped with its runtime behaviour
"verified by code inspection and the compiler" — an honest admission, and not a repeatable standard.

The question this design answers is not "how do we test SwiftUI" in the abstract. It is: **what can be
verified without the user in the loop, and what genuinely still needs their eyes?**

## What the spike measured

Probed on this machine 2026-08-13 (Xcode 26.6, macOS 26.6.1), all four mechanisms working, with the
required TCC grants **already held** by the shell:

| Mechanism | Result | Cost | Proves |
|---|---|---|---|
| `screencapture -l <windowID>` | full-fidelity PNG | ~0.3 s | pixels — type scale, spacing, truncation |
| `AXUIElement` tree dump | greppable text, SwiftUI ids intact | **0.8 s** | structure + strings — order, German, counts, selection |
| `AXSelected` on the row | app navigated (title `182 Projekte` → `0 abgeschlossen`) | ~0.2 s | interaction |
| XCUITest + `xcresulttool export attachments` | `TEST SUCCEEDED`, screenshot recovered | ~35 s warm | deterministic fixture state |

Three findings from the spike shape the design:

- **XCUITest works under ad-hoc signing.** Worth recording given that the same signing gate blocks Focus
  filters at runtime, Widgets and CloudKit. It does not block this.
- **XCUITest launched a second instance while the live app was running**, against the throwaway store
  (the attachment showed `0 Projekte` / *"Nichts hier"*). LaunchServices did not activate the live
  instance instead. This was the largest unknown and it is settled empirically.
- **SwiftUI outline rows expose no `AXPress`.** Selection is driven by setting `AXSelected` on the nearest
  `AXRow` ancestor; a synthetic `CGEvent` click at the element's frame is the general fallback. A probe
  built only around `AXPress` would have appeared broken.

The dump renders content like `AXOutline Description: "Seitenleiste"`, `AXStaticText Value: "Als Nächstes"`,
`AXRow SELECTED`, and preserves the app's own `SidebarNavigationSplitView` identifier.

## The core policy

**Most human-verify carries in this repo are text-and-structure questions, not pixel questions.** Sampling
the ledger: *"Move/Merge pickers never list the node or its descendants"*, *"loose ends come before the
recap"*, *"German in situ"*, *"does the `.searchScopes` bar render under `.sidebar` placement"*,
*"cited-provenance bar on the correct message"*. Every one is answerable from the accessibility tree.

The tree is not faster to *produce* than a screenshot (0.8 s against 0.3 s — the capture wins). It is
better on the two axes that matter: a filtered `grep` over it costs a fraction of the tokens an image
does, and it answers *precisely* — "is this string present, in this order, under this parent" is a
question a screenshot can only be squinted at.

The harness therefore encodes a routing rule, and the skill leads with it:

1. **Text dump first.** Structure, ordering, labels, counts, selection, localization.
2. **Pixels only for genuinely visual questions.** Type scale, spacing, truncation, icon artwork, overlap.
3. **XCUITest for write paths and for anything that must stay true.** Deterministic fixture, no live store.

The failure mode this guards against is reaching for a screenshot to answer a question the tree already
answers precisely.

## Architecture

Four components plus the skill. **No production code changes** — the only additions to `Sources/` are the
fixture seeder and its test (§3), and §3.1 explains why the isolation problem needs no shipped seam.

### 1. `uiprobe` — the live-app driver

A Swift command-line tool at `Tools/uiprobe/`, built by a cached `make uiprobe` rule (`swiftc` →
`.build/uiprobe`), with the binary as its own cache record. This mirrors the `$(CLI)` pattern already in the
Makefile.

**It lives outside `Sources/` deliberately.** `BUILD_SOURCES` globs all of `Sources/`, so a probe placed
there would invalidate the **app build record on every probe edit** — a ~35 s app rebuild to change a
debugging tool. The alternative considered and rejected was a SwiftPM executable target: it buys automatic
lint coverage but pays that rebuild tax and puts a development tool inside the shipped framework package.
Lint coverage is recovered instead by extending the `SWIFT_SOURCES` glob to `Tools`.

Command surface:

| Command | Behaviour |
|---|---|
| `windows` | list Pensieve windows: pid, window id, title, bounds |
| `dump [--depth N] [--grep P]` | accessibility tree as indented text; `--grep` filters to matching lines with their ancestry |
| `find <text>` | locate an element: role, frame, attribute values, ancestor path |
| `select <text>` | set `AXSelected` on the nearest `AXRow` ancestor |
| `click <text>` | synthetic `CGEvent` click at the element's frame centre |
| `key <chord>` | keyboard input (`cmd+f`, `escape`, literal text) |
| `shot [--out <path>]` | capture the window to PNG via its `CGWindowID` |

**Targeting:** by bundle identifier, with `--pid` to disambiguate. This is load-bearing rather than a
nicety — a fixture-backed instance and the live app share `me.mazetti.pensieve`, and a probe that silently
picks the wrong one produces confidently wrong answers.

**Output is line-oriented and greppable**, because its consumer pipes it through `grep` far more often than
it reads it whole. Non-zero exit on "element not found" so a failed lookup is distinguishable from an empty
result.

### 2. `PensieveUITests` — the deterministic harness

A `bundle.ui-testing` target in `project.yml` with `GENERATE_INFOPLIST_FILE: "YES"` (the spike proved
xcodebuild refuses to sign the target without it), registered via `scheme.testTargets`. It depends on
PensieveKit, seeds a store in a fresh temp directory, and launches with `PENSIEVE_DB` /
`PENSIEVE_CAPTURE_DB` in `launchEnvironment`.

Screenshots are attached with `XCTAttachment(screenshot:)` and `lifetime = .keepAlways`, and recovered
from the result bundle with `xcrun xcresulttool export attachments --path <.xcresult> --output-path <dir>`.

Initial coverage targets the carries that recur most across slices — the window renders with content; the
sidebar buckets show correct counts; a node's detail pane orders loose ends **before** the recap (the
slice-A × in-node-find interaction that neither branch could catch alone); Move/Merge pickers exclude self
and descendants; German chrome renders under a forced locale.

### 3. The fixture seeder — in PensieveKit, tested

`UITestFixture.seed(canonicalAt:captureAt:now:)`, built on the existing `openCanonicalDatabase(at:)` seam
that the unit tests already use.

**It lives in PensieveKit with its own unit test asserting the seeded shape**, because a silently-wrong
fixture would invalidate every UI test standing on it, and would do so invisibly — the UI tests would still
pass, against the wrong world. The two alternatives fail plainly: seeding through the `pensieve` CLI cannot
work (loose ends and events only come into existence through ingest), and a committed `.sqlite` fixture
rots across migrations.

Contents are chosen against the real carry ledger, not for completeness: a project with children, an
archived node, open **and** closed loose ends carrying real quotes, `work` / `personal` contexts for Focus,
and events at **fixed offsets from an injected `now`** (−2 h, −3 d, −40 d) so relative labels like
*"vor 3 Stunden"* and dormancy buckets stay stable across runs. Node UUIDs are fixed constants so tests and
`pensieve://` deep links can address them directly.

#### 3.1 Defaults isolation — no production change

**Corrected at plan time against the code.** An earlier draft of this section proposed a
`PENSIEVE_DEFAULTS_SUITE` override on `PensieveDefaults.shared()`. That would have isolated the wrong
process: `shared()` exists for the *CLI and daemon* to read the app's domain cross-process, and the app
itself does not call it. The app uses `UserDefaults.standard` directly in ~10 places plus `@AppStorage`
bindings. The seam would have shipped, been tested, and isolated nothing.

The hazard it was meant to address is real. A UI-test launch inherits whatever Focus context is active
(silently filtering the fixture), and the app writes `lastOpenedAt` on open — which would **shift the real
Briefing "since last visit" baseline on every suite run.** Reads and writes need different answers:

- **Reads → the argument domain.** `NSArgumentDomain` sits at the top of every `UserDefaults` search list,
  including `.standard` and `@AppStorage`, and `XCUIApplication.launchArguments` becomes the process argv.
  So the suite pins the Focus context, narration and dock-icon keys per launch. This is the same mechanism
  as the forced-locale launch already documented in `CLAUDE.md` (`-AppleLanguages '(de)'`), which the
  German test needs anyway.
- **Writes → export and restore around the suite.** `make uitest` runs `defaults export me.mazetti.pensieve`
  to a temp plist before the suite and `defaults import` after. It covers every key, including ones a
  future slice adds and nobody remembers to pin. It is **best-effort**: a crash mid-suite skips the
  restore, but the export is still on disk to recover from.

Rejected: routing all app defaults through one injectable store. That is a real refactor of 10+ call sites
and every `@AppStorage` binding, carried by the shipped app, purely for test isolation — against this
project's surgical-change discipline.

Net effect: **the harness needs no production code change at all.**

### 4. `make uitest` and two Makefile corrections

```make
uitest: .make/uitest   ## Run the app UI test suite (launches a real window)
```

Cached as `.make/uitest` against the built app and the UI-test sources, and **deliberately not part of
`make all`**: the suite launches a real GUI window and takes focus for ~35 s, which would make the most
frequently run command hostile to work alongside.

Two existing rules need narrowing, both correct independent of this work:

- `TEST_INPUTS` globs all of `Tests/`, so adding `Tests/PensieveUITests` would make every UI-test edit
  re-run the whole SwiftPM suite. `swift test` never builds the UI target; narrow to `Tests/PensieveKitTests`.
- Linting `Tools/` takes **two** edits, not one: `.swiftlint.yml` scopes the run with its own
  `included: [Sources, Tests]`, so it needs `Tools` there to lint at all, and `SWIFT_SOURCES` needs it too
  or the `.make/lint` record won't invalidate when the probe changes.

### 5. The skill

`.claude/skills/verify-app-ui/SKILL.md`, a single routing skill. It opens with the three-step policy above,
then the probe's command surface, then the gotchas that cost time when unknown:

- **Detecting a missing TCC grant.** `CGWindowListCopyWindowInfo` returning windows with **no name** means
  Screen Recording is not granted; `osascript`/System Events failing means Accessibility is not. Both are
  granted per host process, so a different terminal needs a one-time re-grant.
- **`--pid` targeting** when a fixture instance and the live app are both running.
- **Recovering screenshots** from `.xcresult` via `xcresulttool export attachments`.
- **The hard rule:** *the live app is for reading and navigating only.* Anything that writes — rename,
  merge, archive, resolve, new node — goes through `make uitest` against a fixture store. A verification
  run must never mutate the real 182-project store.

#### Committing the skill

`.gitignore` line 20 ignores all of `.claude/` (for Claude Code worktree checkouts), so a skill placed there
would be uncommitted and lost on a fresh clone. Git cannot re-include a path whose parent directory is
excluded, so the fix must take the two-line form:

```gitignore
.claude/*
!.claude/skills/
```

## Testing strategy

- **Seeder:** unit-tested in `PensieveKitTests` against the seeded store's shape.
- **Defaults isolation:** nothing to unit-test — it is launch arguments plus a Makefile guard (§3.1). It is
  verified by the German-locale test, which only passes if the argument domain reaches the app.
- **`uiprobe`:** not unit-tested. It is AX-API glue whose only meaningful assertion requires a live app; a
  mock would test the mock. It is verified by use, and its failure mode is loud (non-zero exit, empty tree).
  This is a deliberate exception to the project's testing discipline and is recorded as such.
- **The UI tests themselves** are the test.

## Risks and limits

- **Taste is not covered.** This verifies that the UI *is what was specified*. Whether it *looks right* —
  balance, hierarchy, whether a German string reads naturally in situ — remains the user's judgement. The
  carry ledger will shrink; it will not empty.
- **TCC grants are per host process** and are not portable to a fresh machine or a different terminal.
- **UI tests are flakier than unit tests** by nature. Caching a pass in `.make/uitest` can therefore hide a
  newly flaky test until inputs change; `make -B uitest` forces a run.
- **CI is unverified.** Whether XCUITest runs on a headless GitHub Actions runner is untested and out of
  scope here (§ below).
- **The fixture is a model of the world, not the world.** A bug that only manifests at 182 projects and 968
  loose ends will not appear in it. The live-app probe remains the tool for those.

## Out of scope

- **CI integration.** Deferred until the local loop has proven itself; needs its own probe of headless
  runner behaviour.
- **Snapshot/pixel-diff regression testing.** Image diffing over SwiftUI output is a large commitment with a
  well-known false-positive burden across OS updates. Not now.
- **Driving Settings, the menu-bar extra, Spotlight, Siri or Focus filters.** The first three are reachable
  in principle; Focus filters are blocked at runtime by the signing gate regardless. Start with the main
  window.
- **Replacing `make smoke`.** It verifies the embedded CLI and keeps doing so.
- **Retiring the broken app smoke recipe from `CLAUDE.md`.** It should go, but that is a documentation edit
  for the implementation plan, not a design decision.
