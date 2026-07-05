# Pensieve.app — the three-pane app (Design)

**Date:** 2026-07-05
**Status:** Brainstormed, awaiting review. Design for **Roadmap pillar #2** (see
`../backlog.md`) — the real `Pensieve.app`, built on the proven core (1A/1B/1B-org + sync
daemon) and the shipped v0.1 heartbeat window (`../specs/2026-07-04-pensieve-app-heartbeat-design.md`).
**Audience:** Personal single-user tool (Moritz). Not a product.

## Purpose

Turn the proven headless core into the native macOS app that is *the product*: the surface an
ADHD brain juggling many parallel efforts opens to **reload its whole world** and answer, at a
glance, "where does each project stand, what did I leave open, what's next." The MVP spec
(`2026-07-03-pensieve-mvp-design.md`) sketched this as one paragraph ("three-pane, Mela-like");
this spec is that paragraph made concrete, and adds two capabilities the MVP spec deferred but
Moritz wants surfaced here: **forks** (rescue work orphaned at a decision point) and **talk to
the system** (create strands by describing them).

Design values, in priority order: **great UX and native-macOS polish** (use platform widgets to
the fullest — `NavigationSplitView`, `.inspector`, materials, SF Symbols, live observation),
**grounded provenance** (the north star — every AI-surfaced item cites captured text), and
**simplicity** (ship the app on existing data; light up fork/chat surfaces as their backends land).

## One app, three doors onto one room

The app is **not** three modes. It is one shared **recall view** (the "room") with three entry
paths (the "doors"), all inside a single `NavigationSplitView` window:

- **Browse & explore** — the three-pane split itself (sidebar → list → detail).
- **Cross-project briefing** — the default-selected sidebar item on launch; the home screen.
- **Resume one project** — a global **⌘K command palette** floating over everything: type a few
  letters, jump straight to any project/strand/action.

We pick the *default landing* (Briefing) and make the other two first-class; we do not pick a
winner. This keeps it one coherent app, not three bolted together.

### Window model (native to the fullest)

- Single main window, three-column `NavigationSplitView` (collapsible sidebar).
- **⌘K command palette** overlay for jump-to-anything (the Resume door).
- **⌘⌥I inspector** (`.inspector` modifier, macOS 14+) for deep provenance dives.
- **Native window tabbing** + "Open project in new window" (⌘⌥N on a selection) so two projects
  can sit side by side for cross-referencing recall. Free from AppKit; we just allow it.
- A native toolbar (search field, view toggles, "＋ new strand").

## Sidebar — action-first

The sidebar's primary spine is **state, not structure** (chosen: an ADHD-triage tool should lead
with "what needs me?"). Two sections:

1. **Smart lists** (top, primary):
   - **What's Next** — grounded ranking (days dormant, open loose-end count, unfinished-looking
     branch). Reuses the existing `next` logic.
   - **Dormant** — quiet longer than a threshold.
   - **Blocked** — only where there is real blocker signal (never invented).
   - **Recently Active** — moved since last visit.
   - **Roads Not Taken** — strands left orphaned at a fork (see Forks). The proactive
     "pick-it-back-up" list; the ADHD payoff of the fork feature.
2. **Tree** (below, secondary): the typed tree — domains › projects › strands — expandable, for
   when you want to navigate by structure rather than state.

## Detail view — the room

Selecting anything (a project, a strand, a smart-list row) opens the recall view. Sections follow
the MVP spec's grounded summary fields, generated on demand (never per-event):

- **What It Is** — stable one-liner.
- **Last Work Done** — natural-language recap from recent commits + session activity. The
  highest-value field.
- **Blockers** — shown only on real signal; absent otherwise.
- **Loose Ends** — open items recovered from captured text, **each citing its source**.
- **Timeline** — activity over time (exact presentation an implementation detail; a sparkline-to-
  scrollable-timeline progression).
- **Ancestry trail** (strands only) — see Forks.

### Provenance reveal (the signature interaction) — chosen: inline + inspector

"Provenance-or-it-doesn't-exist" made tangible. Two complementary reveals:

- **Inline expand (default):** click a loose end → it opens in place, showing the **verbatim
  quote** + the source event + a "jump to timeline / open transcript" link. Stays in flow, zero
  chrome. This is the everyday path.
- **⌘⌥I inspector (deep dive):** the right-hand inspector shows full provenance **plus the
  surrounding transcript context**, scrollable — for "why did I flag this."

## Forks — walk back ancestry, rescue orphans

A **fork** is a decision point where work split (Claude offered two paths; you branched adjacent;
you switched branches). The app makes these first-class so the road-not-taken doesn't silently go
cold. **Chosen surface (start simple, native, no separate canvas):**

- **Ancestry trail + siblings** — at the top of a strand's detail, a breadcrumb of the forks that
  produced it; at each fork, its siblings, with **orphaned/dormant siblings flagged and given a
  one-click "resume."** This delivers both "walk back the ancestry" and "see what I abandoned"
  without a graph to lay out or maintain.
- **Roads Not Taken smart list** (sidebar) — proactively resurfaces orphaned strands so you're
  *reminded*, not left to spelunk for them.

**Dependency & phasing:** fork *ancestry* is temporal/causal lineage, distinct from the
containment `parentID` tree — a **new edge type**, closer to the deferred `node_links` idea. Its
**capture backend is not built yet** (see the "Forks as first-class" ledger entry). Therefore the
app defines the *surface* now; the trail and Roads-Not-Taken list **light up when the fork-capture
backend lands** and render empty/absent until then. Branch-switch forks (from `SessionBranch` +
git) are the tractable first data source; transcript-choice detection is a later spike. **The
full pannable "fork canvas" node-graph is parked on the backlog** as a power-view for when many
strands accumulate — a view Moritz expects to enjoy, but not the starting point.

## Briefing — the home screen — chosen: by-project world map

The default landing (the "reload my whole world" moment). **Grouped by project**, not by urgency:

- One compact **card per active project**: what moved since last visit + its single top "next".
- Dormant / orphaned projects collapsed at the bottom (with counts).

Rationale: the sidebar's action-first smart lists *are* the triage/urgency view; the home screen
should do what they don't — reorient you to the whole landscape. This avoids duplicating triage in
two places.

## Talk to the system (stage 1 only, in this app)

A prompt input to **create a strand by describing it**: type a natural-language description → the
`LLMProvider` structures it into `{name, description, kind, parent}` → it is created via the
existing organizing operation. This is the lightweight "quick-add a thing I'm about to work on,"
complementing auto-birth-from-≥2-events. **Stage 2** (a full embedded conversational agent for
instructions + grounded Q&A) is **explicitly deferred** to a later spec — large surface, off the
critical path. Provider stays agnostic via `LLMProvider` (default `claude -p`, no API key).

## Data & write path

- **Reads are live.** Views bind to SQLiteData `@FetchAll` / GRDB `ValueObservation` over
  `pensieve.sqlite`, so the UI updates as the sync daemon writes. Reuse the read-only
  `MonitorSnapshot` kernel pattern where it fits (status/counts).
- **The app self-drains** the spool on launch/foreground (the existing app-fallback guardrail),
  so state is fresh even if the launchd sync agent is between cycles.
- **Writes go through existing PensieveKit operations, not raw SQL.** In-app organizing (create /
  `nest` / `group` / `rename` / `retype`) calls the same operations the CLI already exposes.
  **This does not violate the single-writer principle:** that principle governs *event ingestion*
  (only the ingester drains the spool → canonical events); organizing metadata edits are already a
  legitimate app/CLI write path. Strand creation from Talk-to-system is one such validated write.
- **Cycle guard:** in-app `nest`/create must honor the deferred walk-to-root cycle guard (a UI that
  lets you nest a node under its own descendant would corrupt the tree the whole app renders).

## Native-macOS polish checklist

Not decoration — the point. `NavigationSplitView`; `.inspector`; sidebar/window **materials**
(translucency); **SF Symbols** for states and actions; **semantic colors** for state (active /
dormant / blocked / orphaned) that hold in both appearances; **full light & dark**; native
toolbar, search, context menus, and keyboard-first navigation (⌘K, ⌘⌥I, ⌘⌥N, arrow-key list
nav); `Table`/`List` native selection; live `ValueObservation` so nothing ever looks stale.
Localization (German/English) is a separate ledger item but views must use `LocalizedStringKey` /
`String(localized:)` from day one so chrome is catalog-ready — **never** localizing captured
content or loose-end quotes.

## Build sequence (decomposition into shippable slices)

The app is large; build and verify in increments, each independently useful. Each slice becomes
its own implementation plan (`writing-plans`), starting with slice 1.

1. **Read-only three-pane core** — `NavigationSplitView`, action-first sidebar (What's
   Next / Dormant / Blocked / Recently Active + the tree), the detail recall view with grounded
   summary fields, inline-expand provenance, live `@FetchAll`, app-launch spool drain. *Verify:*
   opening the app shows correct current state for real projects; a loose end's inline reveal
   shows its real verbatim quote + jumps to the source.
2. **Briefing home + ⌘K palette** — the by-project world-map landing; the command palette. *Verify:*
   launch lands on Briefing; ⌘K jumps to any project/strand in two keystrokes.
3. **Inspector + window polish** — ⌘⌥I provenance inspector with surrounding transcript context;
   window tabbing / open-in-new-window; toolbar; keyboard nav; light/dark + materials pass.
4. **In-app organizing writes** — create/`nest`/`group`/`rename`/`retype` via existing ops, with
   the cycle guard. *Verify:* reorganizing in the UI matches the CLI's effect; no cycle can be made.
5. **Talk-to-system (stage 1)** — describe-a-strand prompt → structured create. *Verify:* a typed
   description produces a correctly-typed, sensibly-parented strand.
6. **Forks surface** — ancestry trail + siblings + Roads-Not-Taken list. **Gated on the
   fork-capture backend** (separate spec); until then the surface is designed but dormant. *Verify:*
   once fork edges exist, a strand shows its lineage and orphaned siblings, each resumable.

## Out of scope (this spec / this app)

Menu-bar extra & `LSUIElement` bundle (roadmap pillar #1, precedes/accompanies the app; once the
app exists the menu-bar item launches into Briefing or a project); resident `pensieved`
`SMAppService` (pillar #3 — the launchd sync daemon already covers auto-flow); CloudKit/iOS;
widgets/Siri/Spotlight; the fork-capture *backend*; Talk-to-system *stage 2* (conversational
agent); the full fork canvas; statistical theme discovery; analytics/dependency-graph surfaces.
None are foreclosed; each is on the roadmap.

**Architectural note for those future surfaces:** every glance/integration surface — menu-bar
extra, widgets, Siri/Shortcuts intents, Spotlight indexing — is a **read-only consumer of the
same grounded query kernel** (the `MonitorSnapshot` / `next` pattern). None re-derives summaries
or re-implements ranking; they render what the kernel already computes. Widgets, Siri, and
Spotlight in particular are one coherent "glanceable surfaces" family (roadmap pillar #5) and
should share one spec; the menu-bar extra (pillar #1) is the heartbeat window's next step. This
app spec keeps them out of scope but must not foreclose them: keep read/query logic in
PensieveKit, not in view code, so an extension target can link it.

## Risks / open concerns

- **Fork surface depends on an unbuilt backend.** Mitigated by slice 6 being last and the surface
  degrading to absent when there are no fork edges. The fork-capture spec is the real long pole for
  that feature and should be brainstormed on its own before slice 6.
- **On-demand summary latency** via `claude -p` (spawns a CC process). Mitigated by lazy generation
  + caching + (later) the resident daemon pre-computing. The app must show a graceful pending state,
  never a blank or a fabricated placeholder.
- **In-app writes touching the tree** could corrupt the structure every view depends on — hence the
  mandatory cycle guard and routing through validated ops, never raw SQL.
- **SQLiteData maturity** — as in the MVP spec; GRDB fallback remains.
