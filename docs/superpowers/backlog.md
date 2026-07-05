# Pensieve — Backlog (deferred, not forgotten)

Ideas we've deliberately parked so a phase stays focused. Each is on the roadmap;
none is foreclosed. Revisit when the noted trigger arrives.

The **Roadmap** below is the spine — the sequenced pillars from where we are to the finished
app. Everything after the first `---` is the detail-ledger: features parked out of specific
phases, plus forward ideas, each with its own revisit trigger. Read the roadmap for *where
we're going*; read the ledger for *what we deliberately deferred and why*.

---

## Roadmap — pillars from here to the finished app

**Source of truth for full intent:** `specs/2026-07-03-pensieve-mvp-design.md`. This section
lifts that spec's phasing + "Later" list into one sequenced place so "what's between here and
done" isn't split across two documents. **No new scope is invented here** — sizes are honest,
order is a recommendation, nothing is foreclosed.

### Shipped (the core loop is live)

Capture → ingest → grounded/cited loose ends → `next`/`digest` (1A + 1B); the typed tree &
strands (1B-org); source discovery (`scan`); the launchd auto-flow sync daemon; the v0.1
heartbeat window. **The make-or-break intelligence gate passed.** Dogfooding is on. This is the
hard part, done.

### Pending pillars (sequenced; each needs its own spec unless noted)

1. **Menu-bar item / `LSUIElement` app bundle (v0.2)** — *near-term, small–medium.* Wrap the
   unbundled heartbeat executable in a real `.app`, add a menu-bar readout, hide the dock icon.
   Revisit the Xcode.app-vs-CLT decision here (signing, bundle). Detail entry below.

2. **The three-pane `Pensieve.app` (Phase 3) — THE product.** *The spine; large; being
   designed now (own spec forthcoming: `*-pensieve-app-*`).* Sidebar smart-lists ("What's Next",
   "Dormant", "Blocked") / list / provenance-bearing detail view, live via GRDB observation.
   Currently one paragraph in the MVP spec — this is the biggest single gap to "finished." The
   forward ideas **talk-to-the-system** and **forks-as-first-class** (below) live *inside* this
   app and should be scoped as part of / adjacent to its design.

3. **Resident `pensieved` (`SMAppService`) (Phase 2)** — *medium; partially superseded.* The
   launchd one-shot sync daemon already delivers auto-flow, so a resident agent is now a
   *convenience upgrade* (lower latency, background digest pre-compute), **not** a prerequisite.
   Decide during app design whether the app's launch/foreground drain + launchd cover this, or a
   resident agent still earns its keep. May be reorderable with the app per the spec.

4. **CloudKit sync + iOS companion** — *large; on-ramp preserved, unbuilt.* SQLiteData's opt-in
   `SyncEngine`; sync lives only in the entitled app process (hooks/CLI stay local). "Flip it on,"
   not "build from scratch" — but still a real phase (conflict handling, iOS UI).

5. **System-integration surfaces** — *medium, each independent.* Widgets / Lock Screen widgets,
   Siri / Shortcuts, Spotlight indexing. Native, glanceable extensions of the digest/next data.

6. **Real-time monitoring (FSEvents)** — *small–medium.* Replace/augment interval polling with
   FSEvents on `~/.claude/projects/**` for instant capture. Pure latency win.

7. **Additional source types** — *large, open-ended.* Notion, Entra, browser work, etc. The model
   already allows non-git sources; this is where the deferred **per-kind ingestion-handler
   protocol** (below) finally earns its place (trigger: the 4th source type).

8. **Analytics surfaces** — *medium.* Cross-project dependency graphs, dashboards, token-spend
   charts. Explicitly "Later" in the spec; lowest priority.

**Depth features that thread through the above** (detailed in the ledger, not standalone pillars):
domain-level recursive rollups, cross-cutting soft references (`node_links`) — which
forks-as-first-class builds on, statistical theme discovery (`NLEmbedding`), proactive project
suggestion, and native localization. These deepen existing surfaces rather than standing alone.

---

## Phase 1B-org: the typed tree & strands — DONE (2026-07-04)

**Shipped** on branch `phase-1b-org` (plan: `plans/2026-07-04-pensieve-phase1b-org.md`, spec:
`specs/2026-07-03-pensieve-phase1b-org-design.md`). 75 tests, subagent-driven with a per-task
review gate + an opus whole-branch review. Delivered: the `Project→Node` rename + strict
recursive typed tree; git-common-dir source keying (worktree unification); conservative
tag-then-materialize strand birth (≥2 same-kind events) with lossless repoint of events **and**
their loose ends; `SessionStart` hook + `SessionBranch`; on-device strand naming; `group()`
child re-parenting; organizing CLI + tree `list`. Additive migrations v4–v6; trust gate untouched.

### Deferred out of 1B-org (on the roadmap, not foreclosed)

- **Domain-level recursive rollup** summaries (CTE over descendants) so `status <domain>` shows
  loose ends sitting in child strands. *Trigger: when the tree is deep enough to want rollups.*
- **Per-kind ingestion-handler protocol** (fingerprint/enrich/extract) — a `switch` suffices for
  git+session. *Trigger: a 4th source type.*
- **Cross-cutting soft references** (`node_links`, cycles allowed).
- **Evidence-based loose-end auto-close** (1B/1B-org only surface + age; never auto-close).
- **`SessionEnd` auto-ingest wiring** — session *content* ingestion still runs via
  `pensieve ingest-session --path`; auto-triggering it from a hook is deferred.
- **Retroactive worktree-merge / source re-keying in migration** — v4–v6 do NOT re-key
  pre-1B-org sources to common-dir; a pre-existing repo forks into a new node on its next
  post-upgrade ingest (lossless, fixable with `group()`). Accepted per spec §8.

### Small follow-ups from the 1B-org whole-branch review (deferred, non-blocking)

- **`nest` / `add --parent` cycle guard** — no check prevents nesting a node under its own
  descendant; a resulting cycle becomes an island `list` silently drops (no infinite loop).
  Add a walk-to-root guard. *Protects the `list` view, the tool's main surface.*
- **`NodeCommands.find` name-collision handling** — name-addressed CLI resolves an arbitrary
  row when two nodes share a name (plausible: two `auth` strands). UUID is the preferred path;
  add an "ambiguous name" guard or note it in help text.
- **`SettingsHookInstaller` presence check** is a substring `.contains("capture-session-start")`
  (low risk; our own command string).
- **`SessionBranch` has no retention/GC** — one row per session forever (fine at single-user scale).
- **True v3→v4 upgrade test** — `SchemaV4Tests` exercises the head schema but not a seeded
  pre-v4 `projects` row migrated through v4 (GRDB migrator exposes no `upTo:` seam via
  `openCanonicalDatabase`; migration SQL is simple + additive).

### From the 2026-07-04 real-data validation run

- **Strand naming echoes the newest commit** — on-device naming tends to reuse the most recent
  commit's subject as the strand name rather than synthesizing across the branch's activity
  (real run: a `feat/compose-swarm-reconciliation` strand got named *"Improved code formatting"*
  after its newest commit). Best-effort metadata, **outside the trust gate by design**, and
  fixable with `rename`. *Revisit if strand labels feel consistently off; the naming prompt could
  weight the branchKey and the span of commits, not just the latest summary.* The description was
  correctly grounded — only the short name is weak.
- **(FIXED 2026-07-04) Fractional-second timestamps** — `TranscriptParser` used a default
  `ISO8601DateFormatter`, which rejects Claude Code's `…:43.382Z` timestamps, leaving
  `startedAt`/`endedAt` nil so every session event was stamped at ingest time and dormancy read
  `0d`. Fixed (fractional-then-plain fallback) + regression test `parsesFractionalSecondTimestamps`.

---

## Pensieve.app v0.1: the heartbeat window — DONE (2026-07-04)

**Shipped** on branch `feat/pensieve-app-heartbeat` (plan: `plans/2026-07-04-pensieve-app-heartbeat.md`, spec:
`specs/2026-07-04-pensieve-app-heartbeat-design.md`). 82 tests. Delivered: native read-only SwiftUI
heartbeat window (`swift run PensieveApp`) over a shared, testable `MonitorSnapshot` kernel (pure gather
function, never throws, read-only, WAL-safe). Window shows status dot (active/idle/not-set-up), last-capture
age, spool/event/loose-end counts, polls every 3 s. Unbundled SwiftPM executable (no Xcode, no `.app`
bundle yet).

### Deferred out of v0.1 (on the roadmap, not foreclosed)

- **Menu-bar item / `LSUIElement` app bundle** — the heartbeat window currently runs as an unbundled
  SwiftPM executable (dock icon, focus behavior still to be confirmed). Next phase wraps it in a proper
  `.app` bundle and adds a menu-bar item with `LSUIElement` to hide the dock icon. Own spec required; 
  revisit the Xcode.app decision there (Command Line Tools suffice for now; Xcode.app may be needed 
  for code signing, menu-bar item setup, or `.app` bundle best practices).

### Small follow-ups from v0.1 (deferred, non-blocking)

- **`lastCaptureAt` has no staleness cap** — a node with an ancient capture and 0 events currently reads
  `idle` not `not-set-up` (incorrect signal). Add a staleness check: if `lastCaptureAt` is older than a
  configured threshold (e.g. 30 days), and `eventCount == 0`, treat as `notSetUp`. *Fixes the edge case
  where a dormant project looks "idle" rather than "never started."*
- **Unbundled window visual behavior** — dock icon presence, focus/activation behavior, and close-on-⌘W
  exit behavior of the unbundled `NSApplication` are still to be confirmed at the menu-bar step (Step 1 
  verified a window appears, but in-situ behavior may differ once menu-bar integration is added).

---

## Source discovery (`pensieve scan`) — DONE (2026-07-04)

**Shipped** on branch `feat/source-discovery`. 96 tests. Delivered: filesystem-source abstraction
(`FileSystemSourceType`, `DiscoveredSource`, `DiscoveryCandidate`, `GitSource` with `.git`-directory rule),
write-free walk (`SourceScanner.discover`), best-effort registration + hook install (`SourceScanner.accept`),
CLI `pensieve scan <folder> [--recursive] [--accept]`.

### Deferred out of source discovery (on the roadmap, not foreclosed)

- **Proactively suggest new projects learned implicitly** — from session current working directories and
  commits in unregistered repos, infer candidate projects the user works on but hasn't registered yet.
  Auto-surface as a `next` suggestion. *Trigger: once capture is flowing from multiple sources.*
- **Pass 2: source-discovery settings window** — folder picker, recursive toggle, checkbox candidate list.
  May persist watched folders for periodic rescans. *Pair with the menu-bar step (v0.2);
  brings source discovery into the app proper.*

### Small follow-ups from the source-discovery whole-branch review (deferred, non-blocking)

- **`SourceScanner`'s `(kind, identityKey)` dedup set is untested (near-dead code).** Because
  `GitSource.detect` requires a `.git` *directory*, no non-symlink walk path reaches the same repo
  twice, so the dedup collision branch never fires with the current single kind. A direct unit test
  with a stub `FileSystemSourceType` emitting two `DiscoveredSource`s that share one `identityKey`
  would close the gap. Low risk; the dedup is insurance for future kinds.
- **`normalizedDirectory` builds its URL with `isDirectory: false`** (a directory mislabeled as a
  file) to preserve `URL ==` equality with test-created repo URLs. Fix to `isDirectory: true` when
  the affected tests are switched to compare `.path` instead of whole-`URL` equality.
- **Idempotent-accept test doesn't assert `setupFailed` stayed empty** on the second `accept`.

---

## Native localization — German & English

**Requested:** 2026-07-04. Moritz runs macOS in German but may switch to English; Pensieve
should support both via **native macOS facilities** (no custom i18n layer).

**The native path:** SwiftUI `String(localized:)` / `LocalizedStringKey` + `.strings`/`.xcstrings`
catalogs, with the app following the system language automatically (`AppleLanguages`). Format dates
via `Date.FormatStyle` / `RelativeDateTimeFormatter` (already locale-aware) and numbers via
locale-aware formatters — no hardcoded strings in views. Applies to the SwiftUI app surface
(`PensieveApp` and later three-pane views), NOT the CLI or captured/user data.

**Scope boundary (grounding caveat):** localize only *chrome* — labels, buttons, status words
("active"/"idle"), section titles. **Never translate captured content, quotes, loose-end text, or
LLM-generated strand names** — those are provenance-bearing user data and must stay verbatim.

*Trigger: when the app grows real UI text worth translating (menu-bar step or the three-pane app);
premature to catalog the two-label heartbeat window alone.*

---

## Spike: statistical theme discovery across strands (`NLEmbedding`)

**Parked:** 2026-07-03, during Phase 1B brainstorming.
**Revisit when:** the grounded loose-end/summary layer (1B) is proven and we want the
"broad picture of how strands unfold across the whole tree" — i.e. surfacing
*recurring cross-cutting themes* ("you keep touching auth across three projects")
rather than per-project state.

**Idea:** use unsupervised statistical analysis (word2vec-style embeddings +
clustering) over captured session/commit text and extracted loose ends to surface
recurring themes and candidate cross-cutting strands/concepts automatically.

**Constraints & the native path:**
- **No Python, ever.** The Swift-native route is Apple's `NLEmbedding` (the
  `NaturalLanguage` framework) for on-device word/sentence embeddings — no API key,
  no external service, runs locally. This is the intended implementation surface.
- **Grounding caveat (important).** Opaque embedding clusters are hard to *cite*,
  which cuts against Pensieve's provenance-or-it-doesn't-exist north star. When we
  build this, prefer using embeddings as a *retrieval/grouping aid* that feeds a
  grounded LLM synthesis (which can cite real captured text), rather than surfacing
  raw clusters as if they were findings. Themes must still trace to captured text.

**Why it's a perfect Pensieve dogfood case:** this note is itself a `concept`/`topic`
— a targeted exploration parked for later. When Pensieve can track a strand like this
(let me forget it for a month, then reload full context and continue), it's working.

---

## App: capture & instruct by talking to the system (prompt input → chat)

**Requested:** 2026-07-05.

**Idea, in two stages:**
1. **Capture a strand by describing it** — a prompt/text input in the Pensieve UI where I
   type a description of a new strand and it gets created (name + `description` + `kind`,
   parented sensibly). The lightweight "quick add a thing I'm about to work on" surface,
   as opposed to auto-birth from ≥2 captured events. Pairs with the organizing CLI
   (`add-node`) but conversational and in-app.
2. **Talk to the system** — a fuller Claude/OpenAI/Gemini chat session embedded in the app
   for giving instructions in natural language ("nest auth under the platform node",
   "what did I leave open on the sync daemon", "start a strand for X"). The chat drives the
   same organizing/query operations the CLI exposes, plus grounded Q&A over captured state.

**Scope note:** stage 1 (structured strand creation from a prompt) is achievable early and
independently. Stage 2 (a full conversational agent surface) **can be deferred very late** —
it's a large surface and not on the critical path.

**Constraints & the native path:**
- **Provider-agnostic** via the existing `LLMProvider` protocol (default shells out to
  `claude -p`; I have a subscription, **no API key**). "Claude/OpenAI/Gemini" is a
  someday-choice, not a requirement — don't hardcode a vendor.
- **Grounding caveat.** When the chat *answers questions* about project state, it stays
  under the provenance north star — cite captured text, don't fabricate. When it *creates a
  strand* from my description, the name/description are my own words (user-authored metadata,
  outside the trust gate, like `rename`), which is fine.
- A prompt that creates or re-parents nodes is a **write** — it must go through the same
  validated operations as the CLI (`add-node`/`nest`/`group`), including the deferred
  cycle guard, not raw SQL from model output.

**Stage 1 now specced:** describe-a-strand → structured create is designed in
`specs/2026-07-05-pensieve-app-three-pane-design.md` (slice 5). Stage 2 (conversational agent)
stays deferred to its own later spec.

*Trigger: stage 1 once the app has real interactive UI (the three-pane app, past the
read-only heartbeat/menu-bar steps). Stage 2 much later, once the read/query surface is solid.*

---

## Forks as first-class: capture & visualize strand ancestry and orphans

**Requested:** 2026-07-05.

**The observation:** working is full of *forks*. Claude offers two choices and I pick one;
I branch off to do something adjacent; I switch to another branch and carry on there. Each
is a decision point that splits the work — and today the *road not taken* silently goes cold.
The strands most likely to be forgotten are exactly the ones orphaned at a fork.

**Idea:** make forks first-class in the strand model and surface them prominently, git-branch-like:
- **Capture the fork** — a strand carries not just a parent (containment) but a *branched-from*
  ancestry: which strand/decision-point it split off from, and when. Sibling strands sharing a
  fork point are visibly related.
- **Walk back the ancestry** — from any strand, trace its lineage back through the forks that
  produced it (distinct from the `parentID` containment tree — this is *temporal/causal*
  ancestry).
- **Surface orphans at a fork** — when a fork has branches I started and left dormant, show them
  as "picked up / left open" so I can consciously return to the road not taken.

**Constraints & the native path:**
- **Ground every fork in real captured signal**, not inference. Candidate sources already in
  hand: `SessionBranch` (a session's git branch), git branch creation/switch, worktree
  activity, and — harder — Claude offering explicit choices within a transcript. A fork edge
  should trace to a captured event, consistent with the north star.
- This is likely a **new edge type distinct from `parentID`** — closer to the deferred
  *cross-cutting soft references* (`node_links`, cycles allowed) than to the strict containment
  tree. Design it as causal/temporal lineage, not by overloading containment.
- Detecting "Claude presented two choices and I picked one" from a transcript is the ambitious
  part and may warrant its own spike; branch-switch forks from git/`SessionBranch` are the
  tractable first cut.
- **The full pannable "fork canvas" node-graph is parked here as a power-view** — a 2-D map of
  decision points to walk when many strands accumulate. The app starts with the lightweight
  *ancestry-trail + siblings* surface instead (chosen in the app design). Revisit the canvas once
  strand volume makes the trail feel cramped.

**App surface now specced:** the ancestry-trail + siblings view and the *Roads Not Taken* smart
list are designed in `specs/2026-07-05-pensieve-app-three-pane-design.md` (slice 6), gated on this
capture backend. This entry is the **capture backend** — the still-needed long pole; brainstorm it
on its own before that slice.

*Trigger: once strand auto-birth is proven in dogfooding and the app has a visualization surface
worth walking a tree in (the three-pane app). Branch-switch forks first; transcript-choice
detection as a later spike.*
