# Liquid Glass chrome + the macOS 26 floor (design slice B)

Slice B of the four-slice Claude Design review (`backlog.md` ▸ "Claude Design review of the shipped
app — 2026-08-11"). Slice A ("where was I") shipped and was human-verified 2026-08-12; the backlog's
own trigger for B says *pair with or follow A*.

**The goal is visual: the app should look like it belongs on macOS 26.** The deployment-target bump is
the enabler, not the deliverable. Structural cleanup is explicitly *not* the point — see "What the
floor bump actually buys", which corrects the assumption the backlog entry was written on.

## Why

`project.yml` pins `deploymentTarget.macOS: "15.0"` while the machine runs 26.6 with Xcode 26.6.
Every API this slice wants — `.scrollEdgeEffectStyle`, `.glassEffect`, `.buttonStyle(.glass)` — is
macOS 26+, so today each one would need `if #available` scaffolding at its call site. For a
single-user tool on 26.6 the 15.0 floor buys nothing.

Three concrete complaints, all confirmed in the source:

- **Content bleeds through chrome.** No column adopts a scroll-edge treatment, so scrolling content
  meets the toolbar and the search field at a hard edge.
- **The sidebar status footer reads as bolted on.** `SidebarView.swift:88-118` is a `safeAreaInset`
  band with its own `Divider()` and `.background(.bar)`. The `.bar` fixed an earlier color clash but
  the hairline-plus-opaque-band construction is why it still reads as a strip taped under the
  sidebar. This has been open item #1 since the 2026-07-07 UX carries.
- **The menu-bar popover is the worst-looking surface in the app.** `MenuBarView.swift` renders five
  rows with no visible affordance, and its three-button footer is too narrow for German — the verify
  pass caught `Pensieve öffnen` truncating to `Pensieve öf…`. The string is correct; the row is not.

### What the floor bump actually buys

**API access, and no scaffolding deletion.** The app target contains **zero** `if #available` sites.
The four that exist are all in PensieveKit — `DefaultProvider.swift:52`,
`FoundationModelsProbe.swift:15,26`, `ModelProviderFactory.swift:15` — and they are governed by
`Package.swift`'s `platforms: [.macOS(.v14)]`, not by `project.yml`. Bumping the app target does not
touch them.

**Kit's floor stays at `.v14`, deliberately.** Nothing visual needs it; PensieveKit is also consumed
by the CLI and the test suite; and the concurrent `worktree-on-device-translation` branch adds two
more macOS-26-gated sites in `Sources/PensieveKit/Translation/Translator.swift`. Moving that floor is
a follow-up worth doing *after* translation merges, when the scaffolding it would delete is all
present and countable. Recorded in `backlog.md` rather than done here.

### The boundary with slice C

Slice C (transcript reading: one rail, no nested cards) rewrites `LooseEndRow.swift` and
`TranscriptSegmentView.swift`. **Slice B does the container; slice C does the content.** B may change
how the detail column meets the window — material, margins, measure, scroll edge — and **must not**
edit `LooseEndRow.swift`, `TranscriptSegmentView.swift`, or `TranscriptMessageView.swift`. Both
slices stay independently shippable.

## Design

### 1. The floor

`project.yml`: `deploymentTarget.macOS: "15.0"` → `"26.0"`, then `xcodegen generate` (the project is
generated and gitignored). `Package.swift` is untouched — SwiftPM only requires a package's platform
floor to be at or below the consuming app's, and `.v14 ≤ 26.0` holds.

Consequence: the app may call macOS 26 API unguarded, and will not launch below 26. Acceptable on a
single-user tool whose only machine runs 26.6.

**Confirm the exact API spellings against the installed Xcode 26.6 SDK at plan time.** The backlog's
platform-surfaces section carries this caveat for every macOS 26 surface and it applies here: the
modifier names below are the intended shape, and the plan must pin them to what the SDK actually
exposes before any task is written.

### 2. Main window chrome — the scroll edge

Adopt `.scrollEdgeEffectStyle(.soft, for: .top)` so content dissolves into the chrome above it
instead of sliding under a hard edge. The effect belongs on the *scrolling content*, and the three
columns have different tops (toolbar, search field, toolbar), so it is applied per column rather than
once on `NavigationSplitView`:

| Site | Container |
|---|---|
| `SidebarView.swift:12` | the sidebar `List` |
| `ContentListView.swift` `body` | applied once after the `switch`, which has **four** `List` branches (search results, nodes, loose ends, review suggestions) |
| `DetailView.swift:32` | the detail `ScrollView` |
| `BriefingView.swift:15` | the Briefing `ScrollView` |

`RecallWindowView` reuses `DetailView` and inherits the treatment.

If the modifier does not thread from `ContentListView.body` down into the branch's `List`, the
fallback is applying it inside each of the four branches. The plan should verify which is needed
rather than guessing.

**The toolbar is deliberately left alone.** It carries a single `+` because
`RootView.swift:50-51` records that Refresh was pulled so the native sidebar toggle would not be
pushed into a `»` overflow. The backlog's "the toolbar is otherwise empty" observation predates that
decision; filling it back up would undo a fix.

### 3. Sidebar status footer — pinned, unchromed

`StatusFooter` keeps its `safeAreaInset(edge: .bottom)` placement, and loses its manual chrome: the
explicit `Divider()` and `.background(.bar)` both go, letting the sidebar's own material and the
scroll-edge treatment do the separating.

**Why pinned rather than a row inside the `List`.** A real `List` row scrolls with its content, so
with the project tree expanded the liveness dot would go below the fold and stop being a glance.
The reason the footer reads as bolted on is the hairline and the opaque band, not the pinning — so
the pin stays and the chrome goes. (A non-selectable `List` row with `.selectionDisabled(true)` was
the first choice and was rejected on exactly this ground; recorded under "Rejected".)

The dot color and label continue to come from the `MonitorSnapshot` the model already polls. No new
data, no second timer.

### 4. Kit — additive `NextItem.lastActivityAt`

The popover's rows come from `model.lists.whatsNext`, which is `[NextItem]` — and `NextItem`
(`NextQueries.swift:4-9`) carries `project`, `openLooseEnds`, `daysDormant`, `score` and nothing
else. Slice A added `lastActivityAt` to `BriefingCard` and `NodeFacts`, never to `NextItem`, so the
recency vocabulary the middle column now speaks is not reachable from the popover.

`NextItem` gains `public let lastActivityAt: Date`. The value is already in hand:
`NextQueries.swift:25-28` fetches the latest event to compute `daysDormant`, so the change is the
field declaration plus `lastActivityAt: latest.occurredAt` at the single construction site
(`NextQueries.swift:31` — the only one in the tree; MCP's `WhatsNextItem` is a separate type and is
untouched).

**The field is non-optional, unlike `NodeFacts.lastActivityAt`.** `ranked` does
`guard let latest else { continue }`, so a `NextItem` cannot exist without a latest event. The view
therefore needs no nil branch — worth stating because the sibling type's optionality invites copying
a fallback that cannot fire here.

This is the slice's only PensieveKit change, and it is purely additive: one field, one assignment, no
behavior change to the ranking or to `groundedScore`. No collision with the concurrent translation
branch, which does not touch `NextQueries`.

### 5. Menu-bar popover — a re-entry point, not a scoreboard

`MenuBarView.swift`, rebuilt around the idea that every row is a way back into work.

**Rows.** Each row stays a whole-row `Button` and gains a visible affordance: a hover highlight and
a chevron. The secondary line becomes a **localized relative last-activity date + open count**, read
from the `lastActivityAt` added in section 4 — the vocabulary slice A gave the middle column, so the
two surfaces describe a project the same way. It replaces `N open · Xd dormant`, which slice A
already established is not a fact anyone needs (`dormant 0d`).

The backlog's proposal asks for "a `Fortsetzen` action per row". This design reads that as *the row
is the action, and now looks like it* — a labelled button on each of five rows is heavier and less
Mac-idiomatic than a highlighted row, and the row already navigates today.

**A live hit-testing defect, fixed here.** `MenuBarView.swift:63-70` puts a `Spacer()` between the
node name and the trailing count inside a `.plain` `Button` with no `.contentShape(Rectangle())`.
That is the same construction slice A's verify pass found in the detail pane, where the gap between
text and controls was dead space to hit-testing. Second surface, same bug class; the row gets
`.contentShape(Rectangle())`.

**Footer.** `Open Pensieve` becomes a full-width primary button with `.buttonStyle(.glass)`. Refresh
and Quit demote into an ellipsis `Menu`. This fixes `Pensieve öf…` **structurally** — a full-width
button cannot truncate on German, whereas shortening the string only moves the problem to the next
translation.

**This is the one explicit-glass exception.** Everywhere else the design relies on system material;
a popover genuinely floats over other windows, which is what `.glassEffect` is for. See "Rejected"
for why glass is not applied more widely.

**Width** 300 → 320, so the two-line rows breathe.

### 6. Localization

Any new or changed chrome string needs an `en` **and** a `de` value in
`Sources/PensieveApp/Localizable.xcstrings`. Keys are **not** auto-populated by `xcodebuild` — they
are reconciled by hand.

**Expect a conflict.** The concurrent translation branch's task 9 also edits this catalog. Keep
additions minimal and resolve the overlap by hand at merge time; a whole-file Xcode reformat of this
catalog has caused a merge wrinkle before (`d2df86b`).

Captured content, quotes, loose-end text and LLM-generated names stay verbatim, as always. This
slice touches chrome only.

## Rejected

- **Full glass adoption** — `.glassEffect`/`GlassEffectContainer` on popover rows, node badges and
  the detail header, `.buttonStyle(.glass)` across the toolbar. On macOS 26 the system chrome already
  *is* Liquid Glass; the visible win comes from material meeting content correctly, not from painting
  translucency onto flat surfaces. It also puts glass behind the `NodeBadge` palette, which is the
  one piece of deliberate visual identity the app already has.
- **The footer as a non-selectable `List` row** — the user's first choice, rejected on evidence: a
  `List` row scrolls away and the status stops being a glance. Section 3 keeps the pin and removes
  the chrome instead, which is what actually made it read as bolted on.
- **Filling the window toolbar** — undoes the deliberate `RootView.swift:50-51` decision that keeps
  the native sidebar toggle out of a `»` overflow.
- **Bumping PensieveKit's floor to 26 in this slice** — buys no visual change, reaches into files the
  concurrent translation branch owns, and is better done once after that branch merges.
- **Five literal `Fortsetzen` buttons in the popover** — heavier than a highlighted row, and the row
  is already the action.
- **Shortening the German `Pensieve öffnen`** — treats a layout bug as a copy bug and would recur on
  the next translation.
- **Re-adding a trailing `.inspector`** — already rejected on the evidence in the backlog; the
  `.inspector` was deliberately removed in the 2026-07-08 inline-provenance rework and in-node find
  builds on that decision.

## Out of scope

Transcript internals (slice C). The narration facts-dump quality gate, `Du` vs `user`, and Full
Keyboard Access tab order — all filed separately from the same verify pass, none of them chrome.
Background sync (dead since 2026-08-11; decision recorded to rely on self-drain). Focus filters
(runtime-blocked by ad-hoc signing). Anything gated on a paid Apple team.

## Verification

**Almost everything here is view-only, and the app target has no unit tests by design (`CLAUDE.md`).**
The one testable change is section 4's additive `NextItem.lastActivityAt`, so the count moves from
main's **589** by the one or two tests that field warrants: `ranked` populates it from the latest
event's `occurredAt`, and it agrees with the `daysDormant` computed from the same row. Everything
else is verified by build, lint, catalog parse, smoke launch and eye — padding the count with view
tests the project deliberately doesn't write would be worse than reporting it honestly.

Headless and objective:

- `xcodegen generate`, then `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration
  Debug -derivedDataPath ./.build-xcode build`. **Never pipe the build to `tail`** — per `cfc1189`,
  the pipeline reports `tail`'s exit code and a failed build reads as a successful one.
- `otool -l` on the built binary reports `minos 26.0`. This is the floor bump's objective check;
  "it compiled" is not one.
- `swiftlint --strict` — 0 violations (CI runs it, and it caps files at 400 lines).
- Parse `Localizable.xcstrings`: every key has a `de` value, and format specifiers match between
  `en` and `de`. This covers all keys instead of a handful of surfaces, and is what would have caught
  the six mis-keyed entries that shipped in slice A.
- Smoke-launch the inner binary (`./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`,
  background then `kill`) with throwaway `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB`.

Human-verify (the accessibility sandbox blocks scripting these):

- The popover under `-AppleLanguages '(de)'`: `Pensieve öffnen` renders in full, and the ellipsis
  menu holds Refresh and Quit.
- A popover row click still deep-links to the node, and **the whole row is hittable** — including
  the gap between the name and the trailing count, which is the defect being fixed.
- The sidebar footer cannot take selection, and clicking it does not disturb the sidebar's current
  selection.
- Scroll-edge material at the top of all four scroll containers, in light **and** dark.
- The detail column's reading measure still centers in a wide window (the container change must not
  regress the 2026-07-08 layout fix).
- `open ./.build-xcode/…` from a worktree launches **that** worktree's app — confirm with
  `pgrep -lf Pensieve.app/Contents/MacOS/Pensieve` before concluding anything about a regression.

## Risks

- **`rm -rf .build-xcode` would delete a registered SMAppService bundle.** The standing gotcha
  applies even though background sync is currently dead.
- **`.scrollEdgeEffectStyle` may not thread** from `ContentListView.body` into its four `List`
  branches. Fallback is per-branch application; the plan verifies rather than assumes.
- **`Localizable.xcstrings` will conflict** with translation task 9. Known, hand-resolved.
- **The 26.0 floor is one-way in practice** — after this, the app cannot be run on an older macOS
  without reverting `project.yml`. No consequence on the only machine that runs it.
- **A build without `xcodegen generate` fails misleadingly** — a missing generated project reports as
  `cannot find X in scope`, which reads like a code error and is not one.
