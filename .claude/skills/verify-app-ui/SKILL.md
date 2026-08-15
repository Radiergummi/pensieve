---
name: verify-app-ui
description: Use when verifying any change to Sources/PensieveApp — checking that a SwiftUI view renders what was specified, that ordering/labels/counts are right, that German localization landed, or when tempted to ask the user to click through the app and send a screenshot. Covers the uiprobe accessibility tool and the PensieveUITests suite.
---

# Verifying the Pensieve app UI

The app target has no unit tests. These two loops are how a UI change gets verified
without the user clicking through it.

## Which loop — decide before you run anything

1. **Accessibility tree first** (`make uiprobe`, ~1 s). Structure, ordering, labels,
   counts, selection, localization. Most questions are this kind.
2. **Pixels only for genuinely visual questions** (`uiprobe shot`). Type scale, spacing,
   truncation, icon artwork, overlap. Screenshots cost far more tokens to read and answer
   less precisely — do not reach for one to answer a question the tree already answers.
3. **XCUITest** (`make uitest`, ~35 s) for **anything that writes**, and for anything that
   must stay true.

**Hard rule: the live app is read-and-navigate only.** Rename, merge, archive, resolve,
new node — all of it goes through `make uitest` against a fixture store. Never drive a
write path against `~/Library/Application Support/Pensieve/`; that is the user's real
185-project store.

## Loop 1 — driving the live app

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

## Loop 2 — the deterministic suite

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

- **Missing TCC grants.** `uiprobe windows` printing `<no title — Screen Recording not
  granted>` means Screen Recording is missing. `dump` failing with "no accessible windows"
  means Accessibility is missing. Both are granted **per host process**, so a different
  terminal needs its own one-time grant in System Settings ▸ Privacy & Security.
- **Two instances.** A fixture instance and the live app share `me.mazetti.pensieve`.
  `uiprobe` refuses to guess and tells you to pass `--pid`; get pids from `uiprobe windows`.
- **SwiftUI rows have no `AXPress`.** `select` sets `AXSelected` on the nearest `AXRow`.
  If `select` fails on something that is not a row, use `click`.
- **Stale bundle.** Launch the installed app with `make run`, never Spotlight — every
  worktree build registers another bundle under the same id and LaunchServices picks
  between them. A month-old build on screen reads as a regression.
- **A failing assertion on a *label* is usually the test's error, not a product bug.**
  Confirm what the app actually renders with `uiprobe dump --grep` before changing code.
- **A UI test that passes proves nothing until you have watched it fail.** Mutate the app
  (swap two sections, delete a label) and confirm the test goes red. The ordering test was
  verified this way; the sidebar-count test was not, and is weak because of it.

## What this does not cover

Taste. These loops verify the UI **is what was specified**; whether it *looks right* —
balance, hierarchy, whether a German string reads naturally in situ — is still the user's
call. The human-verify ledger shrinks; it does not empty.

Narration, too: the suite disables it (`-app.narrationEnabled NO`) because it is an LLM
call, so **anything about the recap is unverified here** — including the loose-ends-vs-recap
ordering that motivated the suite in the first place.
