# macOS 26 floor / material adoption slice — human-verify carries

Everything below needs the built app, a real store, and a pair of eyes (or, for a few items, System
Settings toggles no agent can flip and no screenshot can confirm). Subagents implemented, reviewed,
and mechanically verified this branch without a GUI session, so no visual or interactive claim was
made by anyone. These are the checks nobody could perform, not a list of suspected problems.

Build and open:

```
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
open ./.build-xcode/Build/Products/Debug/Pensieve.app
```

## Checks

1. **The scroll edge is a comparison, not a look.** For each of the four columns (sidebar, content,
   detail, Briefing): toggle `.soft` ↔ `.hard` in the source, rebuild, and confirm the top band
   *visibly changes*. "Material is visible at the top" passes even when the modifier landed on the
   wrong view or never applied — the default is `.automatic`.

   Outcome: _______________________________________________

2. **Detail column with ⌘F open** — the scroll view's top meets the find bar, not the titlebar.
   Confirm it looks deliberate.

   Outcome: _______________________________________________

3. **A `RecallWindowView` (⌘⌥N)** — no toolbar at all for the scroll view to meet. Confirm it looks
   deliberate.

   Outcome: _______________________________________________

4. **Which column's top carries the search field** — settles the open question in the spec's
   section 2. `.searchable(placement: .sidebar)` is attached to `ContentListView`, but the note at
   `RootView.swift:35-38` suggests SwiftUI places that chrome in the sidebar.

   Outcome: _______________________________________________

5. **Popover in German** (`-AppleLanguages '(de)'`): `Pensieve öffnen` renders in full; the ellipsis
   menu holds Refresh and Quit; the secondary line reads as German recency (`vor 3 Std. · 12 offen`),
   not English, not `0T ruhend`.

   Outcome: _______________________________________________

6. **The whole popover row is hittable** — click in the gap between the name and the chevron. This is
   the defect being fixed.

   Outcome: _______________________________________________

7. **Popover freshness** — open the popover, note a row's recency; make a commit in another window;
   wait for the watcher; reopen the popover. The recency must be current, not stale from the last
   full refresh.

   Outcome: _______________________________________________

8. **The sidebar footer without its hairline** — does `.bar` still separate it from the scrolling
   rows? Expand the project tree so rows scroll beneath it.

   Outcome: _______________________________________________

9. **Light, dark, Increase Contrast, Reduce Transparency, Reduce Motion** on the sidebar foot and the
   popover. No agent in this slice's execution could toggle these System Settings or see the result —
   all five sub-checks are unverified, not just the two named in the original brief.

   If Increase Contrast makes `.bar`'s edge stop reading as a separator on the sidebar footer, the
   pre-written fix is: add `@Environment(\.colorSchemeContrast) private var contrast` to
   `StatusFooter` (`Sources/PensieveApp/SidebarView.swift`) and restore the `Divider()` conditionally
   — `if contrast == .increased { Divider() }` — inside a `VStack(spacing: 0)`. **Not** an
   unconditional revert of Task 3's change: normal contrast should keep the material-only edge, only
   Increase Contrast needs the hairline back.

   Outcome: _______________________________________________

10. **`open ./.build-xcode/…` launches the worktree's app, not main's** — confirm with
    `pgrep -lf Pensieve.app/Contents/MacOS/Pensieve` before concluding anything about a regression.

    Outcome: _______________________________________________

## Deferred / follow-ups

Recorded here so a later review doesn't re-litigate them, and so the next task that touches this
branch has the context this task's execution surfaced.

- Bump `Package.swift` to `.macOS(.v26)` **after this branch merges into `main`** (the on-device-
  translation branch has already merged, as `225c442`), and delete PensieveKit's four `if #available`
  sites (`DefaultProvider.swift:52`, `FoundationModelsProbe.swift:15,26`, `ModelProviderFactory.swift:15`)
  plus the two `Translator.swift` adds.
- **Test count**: this branch measures 589 (see below), with zero PensieveKit changes. `main` has since
  gained Kit tests from the translation merge, so the post-merge tree's count will be higher than 589 —
  589 is this branch's number, not the merged tree's. Don't read a higher count after merging as a
  regression in the other direction.
- Promote `/tmp/xcstrings-check.py` into `scripts/` if the three-leg check proves worth keeping. Its
  leg 2 (format-specifier parity between `en` and `de`) currently reports false positives on German
  values that reorder arguments with positional specifiers (`%1$@`/`%2$@`) for grammar — confirmed by
  running it on this branch: it flags `'Couldn't %@ "%@"'`, `'%lld of %lld'`, and
  `'%lld matches · searching transcripts %lld/%lld'` purely because the German translations reorder
  the same arguments (e.g. `en=['%@', '%@']` vs `de=['%2$@', '%1$@']`). The specifiers are equivalent;
  the check needs to normalize away the `N$` prefix before comparing, sorted or not.
- 11 pre-existing orphaned catalog keys, found and deliberately not cleaned in this slice (confirmed
  via `leg3-orphaned-key` in the script above — zero Swift-source usages of the bare key): `Inspector`,
  `Provenance`, `Select a loose end`, `Pick a loose end to see its source.`, `Change Type`,
  `claude -p`, `Emoji`, `Foundation Models`, `New Child`, `Rename`, `Sync daemon`. These are leftovers
  from the removed `.inspector` panel, reported by Task 8. `New Child` is the instructive one: the
  catalog holds both `New Child` and `New Child…`, but only the ellipsis form exists in code
  (`NodeOrganizing.swift:129`) — confirmed by reading the file and the catalog's JSON directly.
- The popover's larger composition (two `Divider()`s, the caption header, the undifferentiated
  `ForEach`) — this slice fixed a hit-testing defect, a truncating footer and the secondary line, not
  the composition.
- Full Keyboard Access tab order — app-wide, pre-existing, out of scope.
- **`Package.resolved` drift.** Running the Xcode build (not `swift test`) makes SPM rewrite it with
  roughly 15 new transitive pins from `sqlite-data`'s open dependency range — pre-existing upstream
  drift, unrelated to this slice. Every task in this slice reverted it before committing (this task's
  build did too — see the report). The real fix is one deliberate regeneration commit outside this
  slice's diffs; until that lands, every future task here repeats the revert.
- **The plan's brace claim for `DetailView.swift` is wrong.** The plan states lines 147-148 close the
  `ScrollView` and `ScrollViewReader`. Confirmed by reading the file directly: the **`ScrollView` opens
  at line 32 and closes at line 95** (with `.toolbar`, `.task`, and two `.onChange` chained onto it
  through line 146), and **line 147 closes the `ScrollViewReader`**. `.scrollEdgeEffectStyle(.soft, for: .top)`
  sits at line 148, immediately after the `ScrollViewReader`'s close — the plan's sanctioned fallback
  placement, correct in effect even though the line numbers in the plan don't match what's on disk.
  Whoever resolves this branch's merge into `main` needs this: `worktree-on-device-translation` has
  already merged (`225c442`) and its hunks land at `DetailView.swift:149-153`, immediately adjacent to
  this one.
- Two deferred minors from task reviews:
  - `MenuBarView.swift:136`'s hover fill (`isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)`)
    is the app's only `AnyShapeStyle` in `Sources/` — confirmed by grep. `.quaternary.opacity(isHovering ? 1 : 0)`
    would match the `ShapeStyle.opacity` precedent at `BriefingView.swift:65`
    (`.background(.quaternary.opacity(0.4), in: RoundedRectangle(...))`) instead. (`LooseEndRow.swift:220`
    is `.opacity(showsThumbs ? 1 : 0)` — *view* opacity, a different API, and not the right precedent.)
  - Task 3's commit message (`89b462a`) says "only the Divider goes," but the actual diff
    (`Sources/PensieveApp/SidebarView.swift`) also removed the wrapping `VStack(spacing: 0) { ... }` —
    confirmed by reading the commit's diff. Not a defect, just an imprecise commit message.
- Checked and explicitly **not** defects, recorded so a later review doesn't re-raise them:
  - The new popover-row chevron (`MenuBarView.swift:126`) is not `accessibilityHidden` — checked and
    left as-is. Neither its enclosing `Button` nor `LooseEndRow.swift`'s disclosure `Button` (`:58-67`,
    whose own decorative chevron sits at `:62`) carries an explicit accessibility label — confirmed by
    `grep -n "accessibilityLabel" Sources/PensieveApp/LooseEndRow.swift`, which returns exactly one hit,
    at line 239, inside the unrelated `thumb(...)` helper. Both `Button`s instead get an *implicit*
    label synthesized from their `Text` descendant, and both are `.plain`-styled, so the new chevron
    simply matches existing, working precedent; this is unlike the loose-end thumbs, whose
    `accessibilityHidden` toggle exists for a different reason (keeping a hidden, unrated control out
    of the focus ring).
  - The popover row no longer shows the exact `daysDormant` integer, by design — it renders relative
    recency instead — while `daysDormant` still drives ranking via `groundedScore`
    (`Sources/PensieveKit/Query/NextQueries.swift:14-15`), confirmed by reading the function.
