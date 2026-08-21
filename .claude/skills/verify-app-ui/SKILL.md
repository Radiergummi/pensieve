---
name: verify-app-ui
description: Use when verifying any change to Sources/PensieveApp — checking that a SwiftUI view renders what was specified, that ordering/labels/counts are right, that German localization landed, or when tempted to ask the user to click through the app and send a screenshot. Covers the uiprobe accessibility tool and the PensieveUITests suite.
---

# Verifying the Pensieve app UI

The app target has no unit tests. These loops are how a UI change gets verified
without the user clicking through it.

## Which loop — decide before you run anything

Cheapest and least disruptive first:

1. **Accessibility tree against the live app** (`make uiprobe`, ~1 s, no focus steal).
   Structure, ordering, labels, counts, selection, localization. Most questions are this
   kind, and this answers them without touching the user's window focus at all.
2. **A single filtered `xcodebuild test`** (~15–20 s, opens a window) when you need a real
   interaction against a known fixture, or to check one specific behaviour in the suite.
   Prefer this over the full suite while iterating.
3. **Pixels only for genuinely visual questions** (`uiprobe shot`). Type scale, spacing,
   truncation, icon artwork, overlap. Screenshots cost far more tokens to read and answer
   less precisely — do not reach for one to answer a question the tree already answers.
4. **The full suite** (`make uitest`, ~40–50 s) for **anything that writes**, for anything
   that must stay true, and once at the end of a change as the final check — not as a way
   to iterate.

**Every `make uitest` (or any `xcodebuild test` run) opens a real window and takes focus.**
This is disruptive if the user is working. Read-only questions almost always belong at
level 1 — reach for a test run only when something actually needs to be driven or
exercised, not just inspected.

**Hard rule: the live app is read-and-navigate only.** Rename, merge, archive, resolve,
new node — all of it goes through the test suite against a fixture store. Never drive a
write path against `~/Library/Application Support/Pensieve/`; that is the user's real
185-project store.

## Loop 1 — the accessibility tree, against the live app

```bash
make uiprobe                                    # builds ./.build/uiprobe (cached)
./.build/uiprobe windows                        # pid, window id, title, bounds
./.build/uiprobe dump --grep 'Als Nächstes'     # filtered tree — start here
./.build/uiprobe dump --depth 8                 # whole tree, bounded
./.build/uiprobe find "Briefing"                # role, frame, attributes
./.build/uiprobe select "Abgeschlossen"         # sidebar/list rows
./.build/uiprobe click "Refresh"                # buttons and non-row controls
./.build/uiprobe key cmd+f                      # cmd+f, shift+cmd+g, escape, literal text
./.build/uiprobe shot --out /tmp/window.png     # then read the PNG
```

Non-zero exit means not-found, so a missed lookup is distinguishable from an empty result.

**Put the app back where you found it.** If you navigate away, navigate back.

## Loop 2 — one filtered test, for iterating

`make uitest` has no filter parameter — a filtered run is a direct `xcodebuild` call, the
same invocation `make uitest` dispatches to with a narrower `-only-testing:` target:

```bash
xcodebuild -project Pensieve.xcodeproj -configuration Debug -derivedDataPath ./.build-xcode \
  -destination 'platform=macOS,arch=arm64' -skipMacroValidation -skipPackagePluginValidation \
  -scheme Pensieve \
  -only-testing:PensieveUITests/SidebarCountTests/testLooseEndsCountMatchesFixture test
```

`-only-testing:` accepts either a whole class (`.../SidebarCountTests`) or one method. Swap
`test` for `build-for-testing` to **compile the suite without launching a window** — the way
to check a test change compiles without stealing focus.

Measured on this machine: the full 7-test suite is ~40–50 s wall; one filtered test is
~14–18 s — most of that is per-invocation launch and accessibility-handshake overhead, not
the test body, so filtering does not scale down proportionally. Still meaningfully cheaper,
and — the more important part — it opens **one** window instead of seven in sequence.

**This bypasses `make uitest`'s `defaults export`/`import` guard.** `make uitest` backs up
and restores the `me.mazetti.pensieve` UserDefaults domain around the run so a test run
never shifts the user's real app state (`lastOpenedAt`, sidebar expand state, and now the
custom store root). A filtered `xcodebuild` call does not — if your test reads or writes
that domain, you own restoring it by hand afterward, confirmed with `defaults read`.

**A failing run is diagnosed, not re-rolled.** If a filtered or full run fails, find out why
before running it again. Re-running until it is green is exactly how a flaky suite becomes
an ignored one.

## Loop 3 — the full deterministic suite

```bash
make uitest        # cached; use `make -B uitest` to force
```

Launches a **second** app instance against a temp store seeded by
`UITestFixture.seed(canonicalAt:now:)` (PensieveKit, tested in `UITestFixtureTests`). The
live app may keep running — measured, not assumed.

Recover screenshots from the result bundle:

```bash
LATEST=$(ls -dt .build-xcode/Logs/Test/*.xcresult | head -1)
xcrun xcresulttool export attachments --path "$LATEST" --output-path /tmp/uitest-shots
```

Add a test by copying an existing one in `Tests/PensieveUITests/` and using
`launchPensieve(seededAt:locale:)`. Assert **ordering on `frame.minY`**, never on query
order — query order is not a documented rendering order.

## Reading the tree: what things actually are

Measured while writing the suite, and each one cost a failing test first:

- **A loose end is an `AXButton`, and its text is the accessibility `Description`** — it is
  a disclosure control, not a label. `staticTexts[…]` never matches one.
- **A cited quote is not in the tree until its row is expanded.** Click the loose-end
  button first, then look for the quote as an `AXStaticText`.
- **Section headers render uppercased** ("LETZTE AKTIVITÄT"), so match case-insensitively.
- **Force a locale** in any test that matches chrome (`launchPensieve(locale: "en")`),
  or it silently depends on the developer's system language.

## Gotchas

- **Never run `make run` or `make install` to get a window for probing.** Both replace
  `/Applications/Pensieve.app`. Doing this once mid-plan replaced the user's installed app
  with a worktree Debug build and triggered a macOS `SecurityAgent` auth dialog that sat on
  screen and hard-blocked the test suite entirely (next bullet). If the app is not running
  and you need it running, ask the user rather than installing anything.
- **A pending system authentication dialog blocks XCUITest completely.** It fails with
  `Error Domain=com.apple.LocalAuthentication Code=-4 "System authentication is running."`
  and nothing runs until the dialog is dismissed. Recognize this immediately rather than
  debugging the test target — it means a dialog is sitting on screen, not that tests broke.
- **Missing TCC grants.** `uiprobe windows` printing `<no title — Screen Recording not
  granted>` means Screen Recording is missing. `dump` failing with "no accessible windows"
  means Accessibility is missing. Both are granted **per host process**, so a different
  terminal needs its own one-time grant in System Settings ▸ Privacy & Security.
- **Two instances.** A fixture instance and the live app share `me.mazetti.pensieve`.
  `uiprobe` refuses to guess and tells you to pass `--pid`; get pids from `uiprobe windows`.
- **SwiftUI rows have no `AXPress`.** `select` sets `AXSelected` on the nearest `AXRow`.
  If `select` fails on something that is not a row, use `click`.
- **A UI test can pass for the wrong reason — an ambient default, not the product.** A
  sidebar-collapse assertion once passed only because this developer's live app had
  persisted a collapsed section as the assumed starting state; on a clean machine the same
  helper would have *collapsed* an already-open section and failed against correct code.
  The fix was deriving the assertion from what is actually rendered
  (`SidebarCountTests.revealSidebarSection`), and the way it was caught was setting the
  backing `UserDefaults` key both ways and running the test both ways — not by reading the
  code and reasoning about it. Treat any assertion that depends on ambient `UserDefaults`
  as unproven until you have done the same.
- **A test asserting on a node name must scope to `.cells`.** `BriefingView` renders a bare
  `Text(briefingCard.node.name)` outside any `List`, so `staticTexts["Colibri"]` can match
  both the sidebar row and the Briefing card at once.
- **`make uitest`'s defaults restore can be silently undone by a running app.** If the live
  app is still open when the suite's restore runs, its own next write of cached preferences
  back to `me.mazetti.pensieve` can land after the restore and clobber it. Quit the real app
  before `make uitest` if you need the restore to actually stick.
- **Stale bundle.** Every worktree build registers another `Pensieve.app` under the same
  bundle id, and LaunchServices can front a stale one — a month-old build on screen has read
  as a regression before. This is still never a reason to run `make run`/`make install`
  yourself (see the first bullet): if the live window looks stale, that is the user's call,
  and if it needs relaunching it is `make run`, never Spotlight.
- **A failing assertion on a *label* is usually the test's error, not a product bug.**
  Confirm what the app actually renders with `uiprobe dump --grep` before changing code.
- **A UI test that passes proves nothing until you have watched it fail.** Mutate the app
  (swap two sections, delete a label) and confirm the test goes red.
- **Known limitation: `SpotlightIndexer.reindex` is not guarded off `.build` paths.** Every
  fixture launch clears and repopulates the user's real donated Spotlight entities with
  fixture content, same as the real app would — there is no fixture-vs-live distinction at
  that boundary.

## What this does not cover

Taste. These loops verify the UI **is what was specified**; whether it *looks right* —
balance, hierarchy, whether a German string reads naturally in situ — is still the user's
call. The human-verify ledger shrinks; it does not empty.

Narration, too: the suite disables it (`-app.narrationEnabled NO`) because it is an LLM
call, so **anything about the recap is unverified here** — including the loose-ends-vs-recap
ordering that motivated the suite in the first place.
