# Widgets — the app publishes a digest, the widget renders it

**Date:** 2026-08-22
**Status:** design, ready for review
**Scope:** the first Pensieve widget — a **What's Next** glanceable showing which projects to return
to. A `Codable` digest written atomically into the App Group container by one shared publisher with
two callers (the sync agent and the app), a sandboxed `app-extension` target that only ever *reads*
that file, and a tested pure function deciding what to render when the file is fresh, stale, absent
or from a newer schema.

Deliberately excluded: moving the canonical store into the App Group container (rejected below, with
reasons); the `systemLarge` family; a configurable widget with a node picker (needs an
`AppIntent` and a published node list — its own slice); Lock Screen / Control Center surfaces; any
iOS companion (a different device, therefore CloudKit, not an App Group); and any change to
`NextQueries`' ranking.

All line references are against `main` at `c47ad6c`.

## Problem

`NextQueries` already answers the question this project exists to answer — which of many parallel
projects to pick up next — and the app renders it in a Smart List. But answering it requires opening
the app, and the whole point of the ADHD workflow this serves is reloading context *before* you have
decided to sit down and work. A glanceable surface is the natural home for that, and macOS widgets
are the first-party mechanism.

The gate was never the design. Widgets need a second process, that process is sandboxed, and a
sandboxed process cannot read `~/Library/Application Support/Pensieve` — so Widgets sat behind the
App Group capability, which sat behind a paid team. Both are now resolved far enough to design
against: the membership is live (team `TH593VRB6W`) and the entitlement signs. One residue remains
and is called out under **Sequencing** below.

## Decision: publish a digest; do NOT move the store

The obvious reading of "the widget needs the data" is to move the canonical store into the group
container so both processes open the same SQLite. That was the backlog's long-standing plan. It is
the wrong shape, for four reasons measured on this machine:

1. **A WAL database cannot be opened read-only.** Readers write `-shm` and may recover the `-wal`. A
   "read-only" widget would therefore hold genuine write access to canonical data — the one store
   that will ever sync.
2. **Size against an extension's budget.** The store is 37 MB beside a 34 MB search index with a live
   1.5 MB WAL. Widget extensions get seconds of CPU and tight memory (iOS commonly ~30 MB). Opening
   and WAL-recovering that per timeline refresh is a jetsam candidate.
3. **`0xdead10cc`.** iOS terminates a suspended process still holding a file lock — SQLite locks
   included — on a *shared-container* file. This is the classic app-plus-widget crash, and it bears
   directly on the iOS companion that is wanted later.
4. **Concurrency.** The store is held by the app, the 300 s sync agent, every git hook via the
   embedded CLI, and several `pensieve mcp` processes. Adding a sandboxed reader buys nothing and
   widens a surface that is already the busiest thing in the system.

A widget wants a handful of rows, not query power. So the app publishes what the widget needs, and the
widget renders a file it cannot damage. **This forecloses nothing:**
`PensievePaths.defaultSupportDirectory()` (`Sources/PensieveKit/Support/PensievePaths.swift:13`)
remains the single seam and the only place naming the support directory, so a future migration stays
a one-place change — to be revisited only if a widget ever needs *real queries* (arbitrary search, a
picker over the whole tree, live BM25) rather than a precomputed view.

Rejected alternatives for the transport itself:

- **A shared `UserDefaults` suite.** Less code, but `cfprefsd` caches per process and is known to lag
  across a process boundary — exactly the "widget shows yesterday's numbers" bug that is miserable to
  diagnose. Defaults are for preferences, not payloads.
- **A small SQLite digest store in the container.** Consistent with the other derived stores, but it
  re-imports hazards 1 and 3 above and makes the widget a writer, for roughly eight rows.

## The digest

`Sources/PensieveKit/Widget/WidgetDigest.swift`:

```swift
public struct WidgetDigest: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1
  public static let maximumItems = 8
  public let schemaVersion: Int
  public let generatedAt: Date
  public let context: String?        // "work" / "personal" / nil — what it was filtered BY
  public let items: [Item]

  public struct Item: Codable, Equatable, Sendable {
    public let nodeID: UUID          // → pensieve://node/<id>
    public let name: String          // captured content — NEVER localized
    public let openLooseEnds: Int
    public let lastActivityAt: Date
    public let daysDormant: Int
  }
}
```

A purpose-built DTO, not a serialized `NextItem`: `NextItem` (`Query/NextQueries.swift:4`) carries a
whole `Node` the widget has no use for, and pinning the wire format to a live model would make every
model change a widget-compatibility question. `maximumItems = 8` lets each family slice what it can
show without a second publish path. `schemaVersion` is what lets an older widget refuse a newer file
instead of mis-rendering it. `context` is recorded, not just applied, so the widget can label the
view and a mismatch is visible rather than silent.

Location: `<group container>/widget-digest.json`. One file, replaced atomically.

## Resolving the container — one function, not two

The widget is sandboxed and must resolve the container via
`containerURL(forSecurityApplicationGroupIdentifier:)`. The sync agent and the CLI carry no App Group
entitlement. That is precisely the "two paths that are supposed to agree will drift" setup this
project has been bitten by three times, so it gets **one** implementation in `PensievePaths`, beside
the existing seam, with the group identifier as a single constant:

```swift
public static let appGroupIdentifier = "TH593VRB6W.me.mazetti.pensieve"
public static func groupContainerDirectory() -> URL   // containerURL(...) ?? ~/Library/Group Containers/<id>
public static func widgetDigestURL() -> URL           // groupContainerDirectory()/widget-digest.json
```

The fallback is not a guess. Measured 2026-08-21: for an **unsandboxed** process
`containerURL(forSecurityApplicationGroupIdentifier:)` performs no entitlement check and is
effectively path construction — it resolved for all three naming forms and even with the entitlement
stripped entirely. Entitled callers get the real answer, unentitled callers get the constructed one,
and they are the same path. The constant is deliberately the Team-ID-prefixed form: an App Group is
same-device, so a future iOS companion gets its own container regardless and cross-platform reuse of
one identifier buys nothing.

## The publisher and its two callers

`Sources/PensieveKit/Widget/WidgetDigestPublisher.swift`:

```swift
public enum WidgetDigestPublisher {
  public static func publish(database: any DatabaseWriter, now: Date = Date(),
                            to url: URL = PensievePaths.widgetDigestURL()) throws
}
```

It ranks via `NextQueries`, reads `pensieve.activeFocusContext` from the shared defaults, filters
through the **existing** `NodeContextResolver` predicate (`Query/NodeContext.swift:13`) rather than restating the Focus rule, takes
the top `maximumItems`, encodes, and writes with `.atomic`.

Filtering at publish time (rather than shipping everything and filtering in the view) keeps the widget
consistent with the window, the menu-bar popover and Spotlight by construction, and avoids mirroring
the context value into the group defaults suite just so a sandboxed process could read it.

Two callers, one implementation:

- **Sync agent** — `Sources/PensieveSyncAgent/PensieveSyncAgent.swift`, immediately after
  `SyncRunner(...).run()` succeeds and before the log line. This is what makes the widget correct
  with the app closed, which is most of its life.
- **App** — after a store refresh and on Focus-context change, followed by
  `WidgetCenter.shared.reloadAllTimelines()` for immediacy.

The agent deliberately does **not** call `reloadAllTimelines()`; it writes and lets WidgetKit's own
cadence pick the file up. A timeline reload from a non-app helper is not a behaviour to depend on.

**A publish failure is always non-fatal** — logged via `Log` and swallowed. It must never be able to
break a sync pass or a UI refresh, on the same principle that keeps the capture path sacred.

## What to render — a tested pure function

The interesting rules do not belong in a view that nothing can test:

```swift
public enum WidgetPresentation: Equatable, Sendable {
  case fresh([WidgetDigest.Item])
  case stale([WidgetDigest.Item], generatedAt: Date)
  case noData
  case unsupportedSchema
}
public static func presentation(for digest: WidgetDigest?, now: Date) -> WidgetPresentation
```

Staleness threshold: **20 minutes** — four missed 300 s agent passes, comfortably past normal jitter.

- `noData` renders "Open Pensieve to get started", **never an empty list.** An empty What's Next reads
  as "nothing to do", which is the one lie this widget must not tell.
- `stale` still shows the rows, labelled "as of 14:32", so an outage is visible on the desktop. This
  is not hypothetical: background sync was dead from 2026-08-17 to 2026-08-22 and nothing surfaced it.
- `unsupportedSchema` renders "Update Pensieve" — the reason `schemaVersion` exists.

## The widget target

A new XcodeGen target `PensieveWidget`, `type: app-extension`, linking WidgetKit and PensieveKit (for
`WidgetDigest` and `presentation` only — never the stores).

**It must be sandboxed, and this does not contradict the app's rule.** A widget extension is always
sandboxed by the system, so it gets its **own** entitlements file carrying
`com.apple.security.app-sandbox` **and** the App Group. `Pensieve.entitlements` stays exactly as it
is — no sandbox, no hardened runtime, because the app must keep reading
`~/Library/Application Support` and shelling out to `claude -p`. Both files get a comment saying so,
so a later session does not "fix" one to match the other.

- **Families:** `systemSmall` (open-loose-end total + top project) and `systemMedium` (three rows).
  `systemLarge` is deferred — cheap to add once the thing has been lived with, and guessing a layout
  now is how you ship one nobody wants.
- **Interaction:** reuses the existing scheme. `widgetURL(pensieve://smartlist/whatsNext)` on small;
  a `Link(pensieve://node/<id>)` per row on medium. No new routing — `DeepLinkNavigation` already
  handles both.
- **Timeline:** one entry, `.after(now + 15 min)`. WidgetKit budgets reloads regardless, and the app's
  `reloadAllTimelines()` covers the moments that matter.
- **Build settings:** `STRING_CATALOG_GENERATE_SYMBOLS: "NO"` from the start, for the reason that
  broke the build on 2026-08-21.

## Localization

The widget is a separate bundle and needs its own hand-authored `Localizable.xcstrings`. Only chrome
is localized — "What's Next", "as of %@", "%d open", "Open Pensieve to get started", "Update
Pensieve". Project names arrive in the digest and are rendered verbatim, per the standing rule that
captured content is never translated. Same character-for-character discipline as the app's catalog,
verified against the built bundle with `plutil -p …/de.lproj/Localizable.strings` rather than trusted.

## Testing

The widget target is not covered by `PensieveKitTests`, and `make uitest` drives the app, not
widgets — **there is no automated path to a rendered widget.** That makes the split non-negotiable:
every rule lives in Kit and is tested there, and the view stays a dumb renderer.

In `Tests/PensieveKitTests`:

1. Digest encode/decode round-trip; a file with `schemaVersion` above current decodes to
   `unsupportedSchema` rather than throwing or rendering.
2. Focus filtering, asserted through `NodeContextResolver` — a work context excludes personal nodes,
   and unset nodes remain visible (the existing mute-opposite/show-unset predicate).
3. `presentation(for:now:)` across all four states, including both sides of the 20-minute boundary.
4. `publish` writes a decodable file, caps at `maximumItems`, and orders by `NextQueries`' ranking.
5. A publish failure (unwritable destination) does not propagate to the caller.

Tests 2 and 3 get **mutation-checked** — delete the clause under test, confirm red — per the standing
rule that vacuous tests have shipped here twice.

Manual verification, since nothing automates it: add the widget, confirm both families render, confirm
a row opens the right node, then `defaults write me.mazetti.pensieve pensieve.activeFocusContext work`
and confirm the queue narrows.

## Sequencing — the provisioning step comes first

**The App Group entitlement currently signs but is NOT honoured.** `secd` and `trustd` log on every
launch: `Entitlement com.apple.security.application-groups=("TH593VRB6W.me.mazetti.pensieve") is
ignored because of invalid application signature or incorrect provisioning profile`. No profile
exists — the Provisioning Profiles directory is empty, there is no `embedded.provisionprofile`, and
`xcodebuild -allowProvisioningUpdates` created nothing in a non-interactive shell (there is no App
Store Connect API key and no Xcode session token, so there is no headless path).

The app half works anyway, because the app is unsandboxed and writes the path directly. **The widget
half will not.** So the first step of implementation is: open `Pensieve.xcodeproj` in Xcode.app once,
with the widget target present, and let automatic signing register the App ID and App Group and mint
the profile. Do this **in Xcode, not the portal** — portal identifiers are frequently not deletable,
so a hand-typed identifier or the wrong group-id form is permanent clutter; letting Xcode mint them
from the build guarantees they match the entitlements exactly.

Adding the sandboxed target is what forces the issue: the build will either produce the profile or
fail with a nameable error, both of which beat today's silent "entitlement ignored". Everything else
here is built on that, so it goes first.

## Risks

- **The sandboxed naming rule is unverified.** Measured only for unsandboxed processes, where no
  entitlement check happens at all. macOS documents the Team-ID prefix and iOS documents `group.`;
  if the sandboxed widget rejects the current constant, the fix is one constant in `PensievePaths` —
  but the already-registered portal identifier may not be deletable. Verify with the first build
  before anything depends on the value.
- **Digest freshness depends on the sync agent**, which was dead for five days without anyone
  noticing. The `stale` presentation is the mitigation, and it is why staleness is in scope rather
  than a follow-up.
