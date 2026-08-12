# macOS 26 floor + system material adoption (design slice B)

Slice B of the four-slice Claude Design review (`backlog.md` ▸ "Claude Design review of the shipped
app — 2026-08-11"). Slice A ("where was I") shipped and was human-verified 2026-08-12.

**The goal is visual: the app should look like it belongs on macOS 26.**

**This slice adopts no explicit Liquid Glass.** Two adversarial spec reviews (2026-08-12) ended with
`.glassEffect` and `.buttonStyle(.glass)` both rejected — see "Rejected" for the argument, which is
the spec's own. What survives is the deployment-target bump plus correct use of system material. The
bump's entire payload is **one** API, `.scrollEdgeEffectStyle`; every other change here would work at
the current floor. It is still worth doing — one line, and the alternative is `if #available`
scaffolding in an app target that today has none — but nothing below should be read as depending on
it.

## Why

Three complaints, all confirmed in the source. Two of them are smaller than the backlog entry implies.

- **The columns use the automatic scroll-edge style where `.soft` is wanted.** *Not* "no treatment":
  `ScrollEdgeEffectStyle.automatic` exists, `scrollEdgeEffectHidden(_:for:)` exists — you only ship a
  hide-modifier for an effect that is on by default — and the app already links the macOS 26.5 SDK
  (`otool -l` reports `sdk 26.5`, `minos 15.0`). So the change is `.automatic → .soft`, a style delta,
  and the win is columns whose top edge dissolves rather than cuts. This is the only part of the slice
  that needs the floor.
- **The sidebar status footer reads as bolted on.** `SidebarView.swift:88-118` is a `safeAreaInset`
  band with an explicit `Divider()` plus `.background(.bar)`. Note `.bar` is `Material.bar` —
  **translucent**, not opaque; an earlier draft of this spec had the diagnosis wrong. What reads as
  bolted on is the hairline sitting above a material that already separates. Open item #1 since the
  2026-07-07 UX carries.
- **The menu-bar popover is the weakest surface in the app.** `MenuBarView.swift` renders five rows
  with no visible affordance; its three-button footer is too narrow for German (`Pensieve öffnen` →
  `Pensieve öf…`); and `:60-71` is a `.plain` `Button` whose label `HStack` has a `Spacer()` at `:65`
  and no `contentShape` — the same dead-space hit-testing defect slice A's verify pass found in the
  detail pane. Second surface, same bug class.

### What the floor bump actually buys

**API access, and no scaffolding deletion.** The app target contains **zero** `if #available` sites
(verified by grep over `Sources/PensieveApp`). The four that exist are all in PensieveKit —
`DefaultProvider.swift:52`, `FoundationModelsProbe.swift:15,26`, `ModelProviderFactory.swift:15` —
governed by `Package.swift`'s `platforms: [.macOS(.v14)]`, not by `project.yml`. Bumping the app
target does not touch them. Confirmed empirically: with the app at 15.0, `PensieveKit.o` builds at
`minos 14.0` — Xcode builds SPM package targets at the package's own floor.

**Kit's floor stays at `.v14`, deliberately.** Nothing here needs it, and the concurrent
`worktree-on-device-translation` branch adds two more macOS-26-gated sites in
`Sources/PensieveKit/Translation/Translator.swift`. Worth revisiting after that branch merges, when
the scaffolding a Kit bump would delete is all present and countable. Noted here as a follow-up; not
filed in `backlog.md` yet.

### Why this slice now, and what it defers

**The honest reason is container-before-content, not the backlog's trigger.** The backlog's "pair with
or follow A" is a *permission*, not a priority — slice C's trigger reads "live now", and slice D's
first item is called "the single highest-value idea in the whole review". Quoting B's conditional
trigger as a reason to build B first inverts the backlog's own ordering.

The real argument is sequencing: B's detail-column work and C's transcript rewrite touch the same
pane, and doing the container *after* the content would force C's speaker-rail layout to be
re-litigated against a changed measure. B before C is right for that reason.

**Slice D — "loose ends can end" — is deferred despite being ranked highest, and this spec does not
pretend otherwise.** The cost is real and worth writing down: the app's counts are meaningless until D
lands ("Als Nächstes 155" never shrinks), and B's popover renders `openLooseEnds` on five rows —
investing in presenting the number D exists to fix. If D ships after B, that secondary line gets
re-specified.

### The boundary with slice C

Slice C rewrites `LooseEndRow.swift` and `TranscriptSegmentView.swift`. **B does the container; C does
the content.** B must not edit `LooseEndRow.swift`, `TranscriptSegmentView.swift` or
`TranscriptMessageView.swift`.

**B also leaves `Prose.measure` alone** (`ProseStyle.swift:10`, currently 760). C's proposal is a
speaker column that trades horizontal room for a rail, so the right measure is not knowable until C
knows how wide a rail needs to be. Leaving it to C keeps B's `DetailView.swift` change to a single
added modifier, which matters for the merge risk below.

## Design

### 1. The floor

`project.yml`: `deploymentTarget.macOS: "15.0"` → `"26.0"`, then `xcodegen generate` (the project is
generated and gitignored). `Package.swift` is untouched.

**This raises three binaries, not one.** `options.deploymentTarget` is project-scope — the generated
`project.pbxproj` carries `MACOSX_DEPLOYMENT_TARGET = 15.0` at exactly two lines (the project-level
Debug and Release configs) with no per-target override — so the app, the embedded `pensieve` CLI at
`Contents/Helpers/pensieve`, and `Contents/Library/Helpers/PensieveSyncAgent` all move to 26.0.

**Deliberately accepted rather than overridden.** All three run only on this machine, and CI is
already `runs-on: macos-26` with Xcode 26.6, so the `pensieve --help` smoke step still passes. If the
CLI ever needs to run on an older macOS, the fix is a per-target `MACOSX_DEPLOYMENT_TARGET: "15.0"`
in `project.yml`; not doing that now is a choice, not an oversight.

XcodeGen accepts `"26.0"` in this position (verified with an isolated 2.45.4 probe). Nothing else in
the repo pins a version — only `Package.swift:6` and `project.yml:9`, with `project.yml:63` deriving
`LSMinimumSystemVersion` from `$(MACOSX_DEPLOYMENT_TARGET)`.

### 2. The scroll edge

`.scrollEdgeEffectStyle(.soft, for: .top)` on the scrolling content of each column.

| Site | Container |
|---|---|
| `SidebarView.swift:12` | the sidebar `List` |
| `ContentListView.swift:12` | `body`'s **outer** `Group` |
| `DetailView.swift:32` | the detail `ScrollView` |
| `BriefingView.swift:15` | the Briefing `ScrollView` |

**The `ContentListView` site is `body`, not `normalContent`.** The structure is two levels: `body` is
`Group { if model.isSearching { searchResultsList() } else { normalContent } }` (`:12-19`), and
`normalContent` holds a `switch` with **three** cases (`:24-30`). `searchResultsList()` (`:44`) is a
sibling of the switch, not a case in it. Attaching the modifier to `normalContent` — the obvious
reading of "after the switch" — covers three of the four `List`s and silently leaves the **search
column** untreated, with no compile error. `body`'s outer `Group` is the only single covering site.

**Threading is settled, not assumed.** `.scrollEdgeEffectStyle` resolves to
`TransformScrollStorageModifier<ScrollEdgeEffectStyleTransform>` — the same scroll-storage mechanism
as `scrollDisabled` and `scrollIndicators`, which are applied to ancestors of a scroll view by
design — and it threads through a `Group`. No per-branch fallback is needed.

**Two sites where the top edge is not the window chrome, and the effect may render nothing:**

- `DetailView.swift:26-32` is `VStack { if find.isPresented { FindBar(find:) }; ScrollViewReader { ScrollView { … } } }`.
  With ⌘F open the scroll view's top meets the **find bar**, not the titlebar.
- `RecallWindowView` reuses `DetailView` and has no toolbar for its scroll view to meet at all.

Both are acceptable outcomes (an effect that renders nothing is not a defect), but they must be looked
at rather than assumed, and they are on the verify list.

**Unverified, and the spec does not rest on it:** which column's top actually carries the search
field. `.searchable(…, placement: .sidebar)` is attached to `ContentListView` (`RootView.swift:34`),
yet the note directly below it records SwiftUI placing that chrome in the **sidebar** when it rendered
the scope bar twice. One forced-locale launch settles it; the per-site table above does not depend on
the answer.

**The toolbar is deliberately left alone.** It carries a single `+` because `RootView.swift:50-51`
records that Refresh was pulled so the native sidebar toggle would not be pushed into a `»` overflow.

### 3. Sidebar status footer

Keep the `safeAreaInset(edge: .bottom)` pin. Keep `.background(.bar)`. **Remove only the explicit
`Divider()`** (`SidebarView.swift:93`), letting the material's own edge separate the footer from the
scrolling rows.

**Why not the alternatives.** A non-selectable `List` row scrolls away, so with the project tree
expanded the liveness dot drops below the fold and stops being a glance. Dropping `.bar` as well would
leave a 7pt dot and an 11pt caption on the same surface the rows scroll over, with nothing separating
them — a removal with no positive design content, and this slice specifies a **top**-edge effect only,
so the system would not fill the gap at the bottom. The backlog's third option (glyph plus tooltip,
no label) is a real alternative and is recorded under "Rejected" rather than silently dropped.

The dot color and label continue to come from the `MonitorSnapshot` the model already polls.

### 4. Menu-bar popover — a re-entry point, not a scoreboard

**Rows.** Each row stays a whole-row `Button` and gains a visible affordance: a persistent chevron
plus a hover highlight. The secondary line is rendered by the **existing** `NodeRowMeta`
(`NodeMeta.swift:66-76`), which already draws "relative recency · N open" — the exact string wanted,
already localized, already used by the middle column:

```swift
NodeRowMeta(facts: model.nodeRowFacts[item.project.id])
```

`AppModel.nodeRowFacts` (`AppModel.swift:33`) already holds facts for **every** node with events or
open loose ends, not just the middle column's. Reusing the view — rather than adding a Kit field and
hand-authoring the string — is what actually makes the two surfaces agree: they share one
implementation instead of agreeing by convention until one drifts. It also needs **no new catalog
keys**, which matters because `NodeMeta.swift:29` documents the `"%lld open"` vs `"%@ open"` trap that
silently falls back to English.

**`refreshGlance()` must refresh `nodeRowFacts`.** `AppModel.swift:253-259` sets `snapshot` and
`lists` only; `nodeRowFacts` is written solely by the full `refresh()` at `:281`. Without this the
popover renders whatever the last full refresh left. `NodeFactsQueries.rowFacts` is two grouped
aggregates — cheaper than the `SmartLists.compute` call already on that path.

**Reuse `rowHitArea()` for the hit-testing fix.** `ContentListView.swift:207-213` already defines
`frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())` for exactly this bug. Use
it, so the app has one hit-area idiom rather than two.

**Footer.** `Open Pensieve` becomes a full-width `.buttonStyle(.borderedProminent)`, with Refresh and
Quit demoted into an ellipsis `Menu`. This fixes `Pensieve öf…` **structurally** — a full-width button
cannot truncate on German, whereas shortening the string moves the problem to the next translation —
and it picks up the system accent color, which no other part of this app does.

**Width** 300 → 320, so the two-line rows breathe.

**Not in scope for this slice:** the popover's larger composition — two `Divider()`s, a caption
"What's Next" header, an undifferentiated `ForEach` (`MenuBarView.swift:33-40`). A reviewer fairly
noted that "weakest surface in the app" implies touching composition, not only row ornament. This
slice fixes a hit-testing defect, a truncating footer and a more useful secondary line; the claim is
scoped to that.

### 5. Appearance and accessibility settings

**Nothing in the tree handles these today** — `grep` for
`accessibilityReduceTransparency|reduceMotion|colorSchemeContrast|differentiateWithoutColor` across
`Sources/` returns nothing. For the one slice whose deliverable is material, that gap has to be
closed by decision rather than by omission.

Three decisions, to be verified rather than assumed:

- **Reduce Transparency.** With glass rejected, the exposure is `.background(.bar)` on the footer and
  the system's own scroll-edge material. Both are first-party materials that already respond to the
  setting; the slice adds no custom translucency. **Expected: nothing to do.** Verify by toggling.
- **Increase Contrast.** This setting wants hairlines *back*. Section 3 removes the footer's
  `Divider()`, so the check is whether the `.bar` edge still reads as a separator under it. If it does
  not, the resolution is to restore the `Divider()` conditionally on
  `@Environment(\.colorSchemeContrast)`, not to abandon section 3.
- **Reduce Motion.** `.scrollEdgeEffectStyle` is a material, not an animation, so no interaction is
  expected. Verify.

**Surfaces this slice does not treat**, so "looks like macOS 26" stays a scoped claim: the three
`Settings` tabs, the three `.sheet`s plus `.confirmationDialog` and `.alert` (`RootView.swift:69-99`),
`IconPicker`'s popovers, and the New/Edit modal.

The Full Keyboard Access tab-order defect (`verify/2026-08-11-where-was-i-human-verify.md:132`) stays
out of scope — app-wide and pre-existing — but is named here as a carry rather than passed over.

### 6. Localization

Any new or changed chrome string needs an `en` **and** a `de` value in
`Sources/PensieveApp/Localizable.xcstrings`. Keys are **not** auto-populated by `xcodebuild`; they are
reconciled by hand.

This slice should add **no new keys** — `NodeRowMeta` reuses the middle column's — and it **orphans
one**: removing `Text("\(item.openLooseEnds) open · \(item.daysDormant)d dormant")` leaves
`'%lld open · %lldd dormant'` → `'%1$lld offen · %2$lldT ruhend'` with no Swift literal resolving to
it. Remove the key with the string.

**Expect a conflict** with the concurrent translation branch, which also edits this catalog; hand-
resolve at merge time, as `d2df86b` already did once.

Captured content, quotes, loose-end text and LLM-generated names stay verbatim. Chrome only.

## Rejected

- **`.buttonStyle(.glass)` on the popover's primary button** — rejected on this spec's own argument.
  Glass was refused everywhere else because on macOS 26 the system chrome already *is* Liquid Glass
  and the win comes from material meeting content correctly. The `MenuBarExtra(.window)` popover's
  own surface is exactly that already-glass chrome, so a glass button on it is glass on glass — the
  same "translucency painted on a flat surface" the spec rejects elsewhere, on the app's smallest and
  densest surface. `.borderedProminent` delivers the structural fix identically. (For the record the
  SDK has both `.glass` and `.glassProminent`; an earlier draft named the non-prominent one while
  calling it primary. `GlassButtonStyle(_:)` is 26.1, so a 26.0 floor gets only the parameterless
  forms.)
- **`.glassEffect` anywhere** — including on the popover container, which would double the glass the
  `.window` style already provides. It is also a no-op when glass is disabled system-wide, so it could
  not be relied on as a visual guarantee even if wanted.
- **`NextItem.lastActivityAt`** — an earlier draft added this public Kit field on the false premise
  that recency was unreachable from the popover. `NodeRowFacts` + `AppModel.nodeRowFacts` +
  `NodeRowMeta` already provide it. The real problem was `refreshGlance()` staleness, which section 4
  fixes with one line instead of a public API addition, a test-count move, and a second copy of a
  localized string.
- **The footer as a non-selectable `List` row** — a `List` row scrolls away and the status stops being
  a glance.
- **The footer as a glyph plus tooltip** (the backlog's third option) — viable, and it removes the
  band by removing the content that needs one. Not taken because the status words are read at a glance
  during dogfooding and a tooltip requires a deliberate hover. Revisit if the foot still competes with
  the tree after the `Divider()` comes out.
- **Filling the window toolbar** — undoes the deliberate `RootView.swift:50-51` decision.
- **Bumping PensieveKit's floor in this slice** — buys nothing visual and reaches into files the
  translation branch owns.
- **Five literal `Fortsetzen` buttons in the popover** — heavier than a highlighted row on a five-row
  surface, and the row is already the action.
- **Shortening the German `Pensieve öffnen`** — treats a layout bug as a copy bug.
- **Re-adding a trailing `.inspector`** — already rejected on the evidence; deliberately removed in
  the 2026-07-08 inline-provenance rework after an AppKit titlebar-tiling crash.

## Out of scope

Transcript internals and `Prose.measure` (slice C). The narration facts-dump quality gate, `Du` vs
`user`, Full Keyboard Access tab order. Background sync (dead since 2026-08-11; the decision to rely
on self-drain stands). Focus filters (runtime-blocked by ad-hoc signing). Anything gated on a paid
Apple team.

## Verification

**No PensieveKit changes, so the count stays at main's 589.** With the Kit field dropped this slice is
app-target-only, and the app target has no unit tests by design (`CLAUDE.md`) — matching the
2026-07-07 chrome-polish precedent, which also shipped with no Kit change. Padding the count with view
tests the project deliberately doesn't write would be worse than saying so.

Headless and objective:

- `xcodegen generate`, then `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration
  Debug -derivedDataPath ./.build-xcode build`. **Never pipe the build to `tail`** — per `cfc1189` the
  pipeline reports `tail`'s exit code and a failed build reads as a success.
- `otool -l` reports `minos 26.0` on **all three** binaries: `Contents/MacOS/Pensieve`,
  `Contents/Helpers/pensieve`, `Contents/Library/Helpers/PensieveSyncAgent`.
- `swiftlint --strict` — 0 violations.
- **Catalog check, three legs** — the first two alone cannot detect a mis-key, which is the failure
  this check exists for: a mis-keyed entry has a perfect `de` value and perfectly matched specifiers
  and is simply never looked up. So: (1) every key has a `de` value, **exempting keys marked
  `"shouldTranslate": false`** — two such keys (`'·'`, `'%@'`) have no `localizations` block at all and
  would otherwise report as false failures; (2) format specifiers match between `en` and `de`;
  (3) **diff the localizable Swift literals in `Sources/PensieveApp` against the catalog's keys, both
  directions**. Leg 3 is the one the verify doc names and an earlier draft of this spec dropped.
  Expect pre-existing orphans from the removed `.inspector` panel (`'Inspector'`, `'Provenance'`,
  `'Select a loose end'`) — report them, do not clean them up here.
- Smoke-launch the inner binary with throwaway `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB`.

Human-verify (the accessibility sandbox blocks scripting these):

- **The scroll edge must be checked by comparison, not by presence.** The default is `.automatic`, so
  "material is visible at the top" passes on a modifier applied to the wrong view — or never applied
  at all, which is exactly the `ContentListView` failure mode above. Toggle `.soft` ↔ `.hard`, or
  capture before/after, **per column**, all four.
- The detail column with ⌘F **open** (top meets the find bar) and a `RecallWindowView` (no toolbar) —
  confirm both look deliberate rather than broken.
- Which column's top carries the search field, settling the open question in section 2.
- The popover under `-AppleLanguages '(de)'`: `Pensieve öffnen` renders in full; the ellipsis menu
  holds Refresh and Quit; the secondary line reads as German recency, not English.
- A popover row click still deep-links, and **the whole row is hittable** — including the gap between
  name and trailing text, which is the defect being fixed. Open the popover twice in a row and confirm
  the recency is current, not stale from the last full refresh.
- The sidebar footer without its `Divider()`: does `.bar` still separate it from scrolling rows?
- Light, dark, **Increase Contrast**, and **Reduce Transparency**.
- `open ./.build-xcode/…` from a worktree launches **that** worktree's app — confirm with
  `pgrep -lf Pensieve.app/Contents/MacOS/Pensieve` before concluding anything about a regression.

## Risks

- **`DetailView.swift` is shared with the concurrent translation branch.** As of 2026-08-12 that
  branch (task 11 of 12) has committed changes to `DetailView.swift`, `LooseEndRow.swift`,
  `AppModel.swift`, `AppModel+Narration.swift` and `NodeFindDocument.swift` — an earlier draft of this
  spec claimed `Localizable.xcstrings` was the only shared file, and that is no longer true. Its
  `DetailView` hunks (`:51-58`, `:120-135`, `:149-153`, `:171-180`) do not overlap B's single site at
  `:32`, so git should auto-merge. **Constraint: B adds a modifier at an existing line and must not
  reindent or restructure the `ScrollViewReader`/`ScrollView`/`VStack` nesting** — that reindent would
  span the other branch's hunks, in a file whose `.task` ordering two prior reviews called
  load-bearing. If B ever needs that restructure, sequence it after translation merges.
- **`LooseEndRow.swift` is also touched by translation**, which is a *slice C* file. Worth knowing when
  C is planned; no consequence for B, which does not open it.
- **`rm -rf .build-xcode` would delete a registered SMAppService bundle.** Standing gotcha, still
  applies.
- **The 26.0 floor is one-way in practice** — three binaries stop running below 26 without reverting
  `project.yml`. No consequence on the only machine that runs them.
- **A build without `xcodegen generate` fails misleadingly** — a stale generated project reports
  `cannot find X in scope`, which reads like a code error.
- **Chrome APIs have misbehaved in this exact window arrangement twice** — `.inspector` crashed AppKit's
  titlebar tiling, and `.searchScopes` rendered its bar twice under `.sidebar` placement
  (`RootView.swift:35-38`). `.scrollEdgeEffectStyle` is a third API negotiating between scroll views
  and window chrome in the same three-column layout. **Pre-committed fallback, per site: if a column
  refuses the effect or renders it wrongly, ship no treatment on that column** — do not hand-roll a
  gradient, and do not restructure the column to make the modifier work. Per-column application means
  one bad column costs only that column.
