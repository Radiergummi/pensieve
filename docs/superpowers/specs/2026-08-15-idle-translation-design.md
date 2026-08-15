# Idle translation — the backfill runs itself

**Date:** 2026-08-15
**Status:** design, ready for review
**Scope:** an automatic, in-app, idle-triggered pass over the *same* translation backfill the Settings
button starts — a Foundation background-activity schedule, a tested policy that decides whether now is
a good moment, and one toggle. The existing button keeps its exact meaning: force it **now**.

Deliberately excluded: any launchd-agent involvement (the sync agent stays a reader), a dedicated
translation `SMAppService` agent (rejected below, with reasons), any CLI surface, any new
`TranslationField` case, and any change to what may be translated.

All line references are against `main` at `601ed12`.

## Problem

The translation-settings slice shipped an engine and a button. That was right — an explicit,
cancellable, resumable bulk pass is the correct primitive. But explicit-*only* means the corpus is
translated exactly as often as the user remembers to open Settings ▸ Translation and press
"Translate remaining", and there are two reasons that is not a workable steady state.

**1. Nothing outside Settings knows there is work outstanding.** `translationCoverage` is written by
exactly one caller — `TranslationSettingsTab`'s `.task(id: translationTarget)`
(`TranslationSettingsTab.swift:113`). Close Settings and the app holds no opinion about whether the
corpus is translated. The feature is invisible until you go looking for it, which is precisely the
condition that let it sit at **0 of 1,294** covered for the whole of its first life
(measured 2026-08-14, `backlog.md:1296`).

**2. The corpus is a treadmill, not a finish line.** Every sync cycle ingests new events, births new
strands, extracts new loose ends and generates new narration — each one a new untranslated
`TranslatableUnit`. `TranslatableCorpus.gather` is a query over live data, so its denominator grows
with use. "Press the button once" is therefore not a terminal state; a corpus pressed to 100 % today
decays on its own by tomorrow. On-demand translation cannot absorb that — it covers the text you are
looking at, and two of the three fields the search corpus looks up (`nodeName`, `nodeDescription`)
have no on-demand writer at all. The bulk pass is the only thing that closes the gap, so the bulk pass
has to happen without being asked.

The user's framing was the right one: the button should be the "now" escape hatch, and the normal case
should be that translation happens while nobody is waiting for it.

## The boundary this does not reopen

`backlog.md:1320` records ambient translation in the launchd sync agent as **explicitly rejected, not
parked** — the agent stays a reader so `translation-cache.sqlite` has one writing process and needs no
arbitration. This design keeps that: the writer is still the app.

A **dedicated translation `SMAppService` agent** was considered during brainstorming and rejected on
three grounds:

- **Feasibility is unverified.** `TranslationSession(installedSource:target:)` exists to escape
  SwiftUI's `.translationTask` attachment, but "needs no view" is not "works in a launchd-spawned
  `ProcessType Background` process outside a GUI app". Nothing in this repo answers that; only running
  it would. Building the agent first means finding out last.
- **Folding it into `PensieveSyncAgent` instead is actively harmful.** launchd will not start a second
  instance of a label while one is running, and a bulk pass's wall time has never been measured
  (`backlog.md:1310`). A long translation run would make launchd *skip* sync firings, trading the more
  important job for the less important one. `SystemStatus.lastSyncAt` also reads `sync.log`'s mtime,
  which a translation run writing there would falsify.
- **A second agent doubles this project's worst scar.** `SMAppService` pins registration to path +
  cdhash; that is why background sync was dead for two days and why `BackgroundSyncService.register()`
  does unregister-then-register to heal a stale LWCR. A second Login Items entry, a second plist and a
  second helper is a large standing cost for a maintenance job.

**The consequence, stated plainly: nothing translates while Pensieve is quit.** In practice the app is
resident (menu-bar item, dock icon, liveness watchers), so "the computer is idle" and "the app is
running and idle" coincide almost always — but they are not the same claim, and this design only makes
the second one.

## Design

Four pieces. One is new tested Kit logic; the rest are thin.

The load-bearing decision is that there is **no second execution path**. An idle pass composes the two
methods that already exist, claims the same in-flight slot, and runs through the same completion tail.
The trigger is a parameter, not a fork.

### 1. Kit — `IdleTranslationPolicy` (new, tested)

The only part with logic worth testing is the decision, so it goes in Kit as a pure function over
*injected readings* rather than over sensors:

```swift
public enum IdleTranslationPolicy {
  public static let idleThreshold: TimeInterval = 300
  public struct Conditions: Sendable {
    public let isEnabled: Bool
    public let language: String
    public let isPackInstalled: Bool
    public let idleSeconds: TimeInterval
    public let isLowPower: Bool
    public let thermalState: ProcessInfo.ThermalState
    public let isRunInFlight: Bool
  }
  public static func shouldStart(_ conditions: Conditions) -> Bool
  public static func shouldContinue(_ conditions: Conditions) -> Bool
}
```

`shouldStart` refuses when: the toggle is off · the language is `off` · the pack is not installed ·
`idleSeconds < idleThreshold` · Low Power Mode is on · `thermalState` is `.serious` or `.critical` ·
a run (automatic **or** manual) is already in flight.

`shouldContinue` is the same predicate minus `isRunInFlight` — which is not a stylistic split. The
scheduler cannot interrupt a block it has already started, so "you came back", "the battery got tight"
and "you turned the toggle off" have to be re-evaluated *inside* the run, per unit. Expressing both as
one predicate family means the start condition and the keep-going condition cannot drift apart, which
is the failure this repo has now hit three times (`SearchHitResolver`, `EmbeddableCorpus.corpusNodes`,
`LooseEndStatus.searchable`).

`isPackInstalled` is load-bearing and is the one condition an automatic caller needs that the manual
caller never did. The Settings button is disabled when the pack is absent
(`TranslationSettingsTab.swift:240`), so the guard lives in the *view* — `startTranslationBackfill`
itself has no such check. An automatic pass with no pack installed would therefore run the full work
list, nil every call, write nothing, and do it again in thirty minutes, forever. `SystemTranslator`'s
`InstalledPairCache` caches only positive answers (deliberately, so a mid-session install is picked
up), so each nil'd unit re-probes: ~4.8 ms × 1,294 ≈ 6 s of pure waste per pass. The gate belongs in
the policy.

No new corpus code: the work list still comes from `TranslatableCorpus.gather` +
`TranslationCoverage.measure`.

### 2. App — `TranslationActivityScheduler` (new, thin, ~50 lines)

Wraps `NSBackgroundActivityScheduler(identifier: "me.mazetti.pensieve.translation")` — Foundation's
own primitive for discretionary maintenance work, which is what the "Platform primitives first" rule
points at here. `repeats = true`, `interval` 30 min, `tolerance` 10 min,
`qualityOfService = .background`.

The scheduler already defers on battery, thermal pressure and Low Power Mode. The policy re-checks
those anyway, because the scheduler's notion of "optimal" is about the *machine*, not about whether a
human is at the keyboard — and it holds no opinion at all about our toggle, our language setting or our
in-flight run.

Reading the sensors is this file's only other job, and they live nowhere else:

- `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)`
  — seconds since the last human input, where the `~0` event type is `kCGAnyInputEventType`. Not an
  event tap: it needs no entitlement and raises no Accessibility prompt. It also covers screen lock,
  screensaver and display sleep for free, since idle time simply keeps climbing through all three.
- `ProcessInfo.processInfo.isLowPowerModeEnabled` / `.thermalState`.
- `LanguageAvailability().status(from:to:) == .installed` for `isPackInstalled`. Unlike the other two
  this one is `async` (~4.8 ms warm, measured in `TranslationLanguageCatalog`), so the block awaits it
  before building `Conditions`. Once per firing, against a half-hourly cadence — the cost the policy
  exists to prevent is 1,294 of these, not one.

The block returns `.finished` when a pass was started and `.deferred` when the policy refused, so a
refusal is not recorded as work done. Exactly when the system re-fires after `.deferred` is the
system's business and nothing here depends on it — worst case it waits another interval, which is
acceptable for maintenance work by definition.

**The block does not await the translation itself.** It awaits only the two cheap steps — the
availability probe and the coverage measurement — and returns once the run has been *started*;
`startTranslationBackfill` owns the run and its completion, as it does for the button. Holding the
scheduler's completion handler open for a pass of unmeasured length would be a promise about wall time
this design cannot make, and it would buy nothing: a second firing landing mid-run is already refused
by `isRunInFlight`.

Installed from `AppModel.start()` alongside the liveness watchers, and app-lifetime like them.

### 3. App — `AppModel.runIdleTranslationPass()` + a trigger on the existing start

The pass is a composition, not a reimplementation:

```swift
func runIdleTranslationPass(idleSeconds: TimeInterval, isPackInstalled: Bool) async {
  guard IdleTranslationPolicy.shouldStart(conditions(idleSeconds:isPackInstalled:)) else { return }
  await measureTranslationCoverage()          // existing: off-main gather, token-guarded
  startTranslationBackfill(trigger: .automatic)  // existing: every guard applies verbatim
}
```

`measureTranslationCoverage()` is reused rather than duplicated because the idle pass needs exactly
what it produces — a `TranslationCoverage` carrying its language and its `missing` work list — and
because measuring through the same method keeps the coverage the Settings row would show and the
coverage the pass acts on the same value. `startTranslationBackfill` then re-checks everything
(run-not-in-flight, language non-empty, coverage-language matches, missing non-empty) after the await,
so the gap between measure and start is already covered by guards that exist today.

Two small additions to existing code, both minimal:

- `TranslationBackfillRun` gains a `trigger: Trigger` (`.manual` / `.automatic`), and
  `startTranslationBackfill(trigger:)` takes it with `.manual` as the default — so every existing call
  site is unchanged.
- The run's per-unit progress closure — which already exists and already hops to the main actor
  (`AppModel+Translation.swift:84`) — re-evaluates `shouldContinue` **for automatic runs only** and
  cancels the run when it returns false. A manual run must never be cancelled for "the user is typing":
  they pressed the button.

That closure is the whole interruption mechanism; no second timer, no polling task.
`TranslationBackfill.run` checks `Task.isCancelled` before each unit, so the run stops at the next unit
boundary with everything already written intact. Resumable-by-construction is exactly why stopping
early is free — the next idle window picks up where this one left off, paying only for what is missing.

The completion tail is reused verbatim: re-measure coverage, bump `translationRevision`, one debounced
whole-corpus index rebuild.

**Everything about the running state is already built.** Because an automatic run occupies the same
`translationBackfillRun` slot, the Settings progress row renders it (`run.language == translationTarget`
holds — an automatic run uses the resolved target), its **Stop** button cancels it, the "Translate
remaining" button is already `.disabled(model.translationBackfillRun != nil)`, and a language switch
already cancels it via the tab's `.onChange`. Turning the toggle off mid-run also stops it, for free,
because `isEnabled` is part of `shouldContinue`. No new UI state, no new cancellation path.

### 4. Settings — one toggle

`Translate automatically when idle` in the Translation tab, rendered only when a target is selected
(under the same `#available(macOS 26, *)` branch as the rest). `@AppStorage` bound to a new
`AppDefaults` key, default **on**, using the same `object(forKey:) == nil ? true` accessor pattern as
`narrationEnabled` and `backgroundSyncEnabled` — so the non-View reader (the policy's `isEnabled`)
cannot disagree with the toggle before Settings has ever been opened.

A short footer states what it does, in one sentence, because "idle" needs saying: translation runs when
you have been away for a few minutes and the Mac is not on battery-saver.

Both new strings are localized en + de by hand (the catalog is IDE-populated only — see
`CLAUDE.md`), and neither is content.

## Degradation

| Condition | Behaviour |
|---|---|
| Toggle off | No pass. The button still works. |
| Target `off` | No pass; no store opened and no model asset loaded (the lazy-store rule holds). |
| Language pack absent | No pass — the policy refuses before any translator call. Settings still offers Download. |
| Low Power Mode / thermal ≥ serious | Refuse, `.deferred`; retried on a later firing. |
| User active | Refuse, `.deferred`. A run already going stops at the next unit boundary. |
| Manual run in flight | Refuse. One slot, one run. |
| Corpus gather fails | `measureTranslationCoverage` sets nil; `startTranslationBackfill` refuses. |
| Nothing missing | `startTranslationBackfill` refuses on its empty-`missing` guard. Costs one gather. |
| App quit | Nothing translates. Named above as the cost of the in-app choice. |
| macOS < 26 | `translator` is nil and the whole section is unavailable. Unreachable at the app's 26.0 deployment target; kept to mirror surrounding code. |

## What does not change

- **The trust gate.** No case is added to `TranslationField`, nothing here reads a `quote`, a
  transcript message or `TranscriptVocabulary.injectionMarkers`, and no `LLMProvider` is involved. This
  changes *when* an existing translation runs, never *what* may be translated.
- **The single writing process.** Still the app.
- **`TranslationBackfill`.** Not touched. It was already serial, idempotent, resumable and cancellable;
  this design exists because it was built that way.
- **The manual button.** Same label, same behaviour, same enablement.
- **No `EvalTask`.** Translation is the on-device `Translation` framework, which exposes no model
  choice — the `registry ↔ config` test is unaffected, as the translation-settings spec established.

## Testing

**Kit — real tests, mutation-checked.** `IdleTranslationPolicy` gets one test per refusal reason, each
written down with the mutation it must fail under (delete the low-power check → this test fails; drop
the pack-installed gate → that one fails), plus a test pinning that `shouldContinue` and `shouldStart`
differ in exactly one condition. This repo has shipped vacuous tests twice and caught them only by
running the mutation, so running them is part of the task, not a review note.

**App — no automated signal, stated plainly.** The app target has no unit tests, and the documented
smoke-launch renders no view body, so the scheduler, the pass and the toggle will be verified by the
compiler and by inspection only. An accessibility/XCUITest harness is in flight but uncommitted at
`601ed12`; this design does not depend on it and should not wait for it.

**Human-verify carries** (need the installed app, a real store and an installed pack):

1. With the toggle on and a pack installed, leave the Mac untouched for 30+ min, then open Settings ▸
   Translation and confirm coverage climbed on its own.
2. Catch a pass running: the progress row and its Stop button render, and "Translate remaining" is
   disabled.
3. Touch the keyboard mid-pass and confirm it stops within a unit, with coverage retaining everything
   already written.
4. Toggle off mid-pass → stops. Switch language mid-pass → stops (existing `.onChange`).
5. Select a target whose pack is **not** installed and confirm no pass ever starts (no repeated
   nil'd work in `log show --predicate 'subsystem == "me.mazetti.pensieve"'`).
6. German in situ for the two new strings.

## Deliberately left open

- **The two constants are unmeasured.** 30 min interval / 5 min idle threshold are judgement, not
  measurement — there is nothing to measure them against until a pass has been observed. *Revisit
  trigger:* the first completed idle pass, whose wall time also closes the still-open ETA item
  (`backlog.md:1310`).
- **A no-op pass is not free.** A pass over a fully-translated corpus still costs one canonical gather
  plus one store read per unit (~1,294 today) before refusing. On an idle machine at half-hourly
  cadence that is acceptable, and it is the same cost the existing open item about coverage already
  names (`backlog.md:1328`). *Revisit trigger:* the same one — if coverage becomes slow enough to feel,
  both callers get the grouped query at once.
- **Newly translated text repaints while you are reading.** A completed pass bumps
  `translationRevision`, so an open pane can switch to German mid-read. This is what the feature is
  for, and it is behaviour the manual button already has; named so it is not mistaken for a defect.
- **Nothing translates while the app is quit.** The direct, accepted cost of the in-app choice.
  Reopening it means reopening the agent question above, including its unverified feasibility.
