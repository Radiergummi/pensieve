# Idle Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the translation backfill run itself while the Mac is idle, instead of only when someone remembers to press a button in Settings.

**Architecture:** Four pieces, one of them new logic. A tested PensieveKit `IdleTranslationPolicy` decides whether now is a good moment, over readings injected by the caller. An app-side `IdleSensors` reads those three machine signals in one place. `AppModel.runIdleTranslationPass()` composes two methods that already exist (`measureTranslationCoverage` then `startTranslationBackfill`) and claims the same in-flight slot as the manual button, so there is exactly one execution path and the trigger is a parameter. A `TranslationActivityScheduler` wrapping `NSBackgroundActivityScheduler` fires it. One Settings toggle gates the whole thing.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing (`@Test`/`#expect`), SwiftUI, Foundation `NSBackgroundActivityScheduler`, CoreGraphics `CGEventSource`, the `Translation` framework's `LanguageAvailability`, XcodeGen, GNU make.

**Spec:** `docs/superpowers/specs/2026-08-15-idle-translation-design.md`

## Global Constraints

- **`make` targets are the canonical interface.** `make test [FILTER=<name>]`, `make lint`, `make build`, `make all`. Raw `swift`/`xcodebuild` only when debugging a recipe.
- **Naming: explicit, no abbreviations.** `database`/`node`/`looseEnd`/`conditions`, never `db`/`n`/`le`/`c`. SwiftLint `identifier_name`; `line_length` warning 140. CI runs `swiftlint lint --strict`.
- **Tests are Swift Testing** (`@Test`, `#expect`), in `Tests/PensieveKitTests/`. The **app target has no unit tests** — app-side work is verified by `make build` + inspection.
- **`AppModel.swift` must stay under 400 lines** (`swiftlint --strict` caps it; the file is at ~404-line risk historically — check with `wc -l` before and after, and move code to an `AppModel+*.swift` extension if it would cross).
- **SQLiteData predicates use `.eq(x)`, never `== x`.** (Not expected in this plan; stated because it is a repo-wide trap.)
- **No Python.** Swift and shell only.
- **Commit after every task.** Never put backticks inside `git commit -m "…"` (they shell-execute) — use `-F -` with a heredoc.
- **The String Catalog is hand-authored.** `xcodebuild` does NOT populate `Localizable.xcstrings`; keys are written by hand and must match the Swift literal exactly, or German silently falls back to English.
- **Trust gate untouched.** No case may be added to `TranslationField`; nothing here reads a `quote`, a transcript message, or `TranscriptVocabulary.injectionMarkers`.
- **Deployment target is macOS 26.0** (`project.yml:9`). `LanguageAvailability` is 15+ and needs no availability annotation; `TranslationSession(installedSource:)` is 26+.

## Plan-time deviation from the spec (deliberate, with reason)

The spec says `shouldContinue` is "the same predicate minus `isRunInFlight`". Implementing it that way would keep `isPackInstalled` in the mid-run check — and that reading is the **async** `LanguageAvailability().status(from:to:)` at ~4.8 ms, evaluated once per translated unit. Over a 1,294-unit pass that is ~6 s of probing, which is precisely the waste the pack gate exists to prevent.

So the split is: `Conditions` holds only the **cheap, synchronously readable** signals, and the two start-only facts (`isPackInstalled`, `isRunInFlight`) are parameters of `shouldStart`. The mid-run caller then physically cannot forget a field, because it has none to pass. Mid-run pack loss is already covered by existing degradation — `translate` returns nil and the run writes nothing.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/PensieveKit/Translation/IdleTranslationPolicy.swift` (new) | The decision, as a pure function over injected readings. The only new logic. |
| `Tests/PensieveKitTests/IdleTranslationPolicyTests.swift` (new) | One test per refusal reason, each mutation-checked. |
| `Sources/PensieveApp/AppDefaults.swift` (modify) | The toggle's key + the non-View accessor that must not drift from it. |
| `Sources/PensieveApp/Settings/TranslationSettingsTab.swift` (modify) | The toggle and its footer. |
| `Sources/PensieveApp/Localizable.xcstrings` (modify) | Two hand-authored en + de keys. |
| `Sources/PensieveApp/IdleSensors.swift` (new) | The three machine readings + the one async pack probe, in one place so the start decision and the keep-going decision read the same sensors. |
| `Sources/PensieveApp/AppModel.swift` (modify) | `TranslationBackfillRun.trigger`; the scheduler property; installing it in `start()`. |
| `Sources/PensieveApp/AppModel+Translation.swift` (modify) | `startTranslationBackfill(trigger:)`, the per-unit yield, and `runIdleTranslationPass()`. |
| `Sources/PensieveApp/TranslationActivityScheduler.swift` (new) | The `NSBackgroundActivityScheduler` wrapper. Nothing else. |

---

### Task 1: `IdleTranslationPolicy` — the decision, tested

**Files:**
- Create: `Sources/PensieveKit/Translation/IdleTranslationPolicy.swift`
- Test: `Tests/PensieveKitTests/IdleTranslationPolicyTests.swift`

**Interfaces:**
- Consumes: `TranslationTarget.off` (an empty `String`), from `Sources/PensieveKit/Translation/TranslationTarget.swift`.
- Produces: `IdleTranslationPolicy.Conditions(isEnabled:language:idleSeconds:isLowPower:thermalState:)`, `IdleTranslationPolicy.shouldContinue(_:) -> Bool`, `IdleTranslationPolicy.shouldStart(_:isPackInstalled:isRunInFlight:) -> Bool`, `IdleTranslationPolicy.idleThreshold: TimeInterval`. Tasks 3 and 4 call all four.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/IdleTranslationPolicyTests.swift`:

```swift
import Testing
import Foundation
@testable import PensieveKit

@Suite struct IdleTranslationPolicyTests {
  /// Every signal in the state that should permit a pass. Each test names the ONE thing it changes,
  /// so a test that starts passing for the wrong reason is visible in its own body.
  private func ready(
    isEnabled: Bool = true,
    language: String = "de",
    idleSeconds: TimeInterval = 600,
    isLowPower: Bool = false,
    thermalState: ProcessInfo.ThermalState = .nominal
  ) -> IdleTranslationPolicy.Conditions {
    IdleTranslationPolicy.Conditions(isEnabled: isEnabled, language: language,
                                     idleSeconds: idleSeconds, isLowPower: isLowPower,
                                     thermalState: thermalState)
  }

  @Test func startsWhenTheMachineIsIdleAndEverythingIsReady() {
    #expect(IdleTranslationPolicy.shouldStart(ready(), isPackInstalled: true, isRunInFlight: false))
  }

  /// Mutation: delete the `idleSeconds >= idleThreshold` clause and this fails.
  @Test func refusesWhileTheUserIsActive() {
    let justTooSoon = ready(idleSeconds: IdleTranslationPolicy.idleThreshold - 1)
    #expect(!IdleTranslationPolicy.shouldStart(justTooSoon, isPackInstalled: true, isRunInFlight: false))
    #expect(!IdleTranslationPolicy.shouldContinue(justTooSoon))
    // The boundary itself permits: "away for the threshold" is away.
    #expect(IdleTranslationPolicy.shouldContinue(ready(idleSeconds: IdleTranslationPolicy.idleThreshold)))
  }

  /// Mutation: delete the `isPackInstalled` clause and this fails.
  ///
  /// This is the defect-prevention test. `startTranslationBackfill` has no pack check of its own —
  /// the manual path is guarded in the VIEW, by the button's `.disabled(!isInstalled …)`. An
  /// automatic caller does not pass through the view, so without this gate a pass with no pack
  /// installed runs the whole work list, nils every call, writes nothing, and repeats forever.
  @Test func refusesWithoutAnInstalledLanguagePack() {
    #expect(!IdleTranslationPolicy.shouldStart(ready(), isPackInstalled: false, isRunInFlight: false))
  }

  /// Mutation: delete the `isRunInFlight` clause and this fails.
  @Test func refusesWhileAnotherRunHoldsTheSlot() {
    #expect(!IdleTranslationPolicy.shouldStart(ready(), isPackInstalled: true, isRunInFlight: true))
  }

  /// Mutation: delete the `isEnabled` clause, or the `language` clause, and one of these fails.
  @Test func refusesWhenTurnedOffEitherWay() {
    #expect(!IdleTranslationPolicy.shouldContinue(ready(isEnabled: false)))
    #expect(!IdleTranslationPolicy.shouldContinue(ready(language: TranslationTarget.off)))
  }

  /// Mutation: delete either power clause and one of these fails.
  @Test func refusesWhenThePowerBudgetIsTight() {
    #expect(!IdleTranslationPolicy.shouldContinue(ready(isLowPower: true)))
    #expect(!IdleTranslationPolicy.shouldContinue(ready(thermalState: .serious)))
    #expect(!IdleTranslationPolicy.shouldContinue(ready(thermalState: .critical)))
    // Warm is not constrained: `.fair` is the state a Mac sits in under ordinary load.
    #expect(IdleTranslationPolicy.shouldContinue(ready(thermalState: .fair)))
  }

  /// The two predicates must differ in EXACTLY the start-only facts, or the start condition and the
  /// keep-going condition drift apart — the failure this repo has already hit three times
  /// (`SearchHitResolver`, `EmbeddableCorpus.corpusNodes`, `LooseEndStatus.searchable`).
  @Test func continuingDiffersFromStartingOnlyInTheStartOnlyFacts() {
    // Ready in every shared respect, refused only by a start-only fact: keeps going, cannot start.
    #expect(IdleTranslationPolicy.shouldContinue(ready()))
    #expect(!IdleTranslationPolicy.shouldStart(ready(), isPackInstalled: true, isRunInFlight: true))
    #expect(!IdleTranslationPolicy.shouldStart(ready(), isPackInstalled: false, isRunInFlight: false))
    // Every SHARED refusal refuses both, with the start-only facts at their most permissive.
    for refused in [ready(isEnabled: false), ready(language: TranslationTarget.off),
                    ready(idleSeconds: 0), ready(isLowPower: true), ready(thermalState: .critical)] {
      #expect(!IdleTranslationPolicy.shouldContinue(refused))
      #expect(!IdleTranslationPolicy.shouldStart(refused, isPackInstalled: true, isRunInFlight: false))
    }
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test FILTER=IdleTranslationPolicy`
Expected: FAIL — compile error, `cannot find 'IdleTranslationPolicy' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PensieveKit/Translation/IdleTranslationPolicy.swift`:

```swift
import Foundation

/// Whether now is a good moment to translate the corpus nobody asked for.
///
/// Pure, over readings the caller injects rather than sensors it reads itself — so the decision is
/// testable without a Mac in a particular state, and so the app-side sensor code stays a thin adapter
/// with no branching in it.
///
/// The split between the two predicates is NOT stylistic. `NSBackgroundActivityScheduler` cannot
/// interrupt a block it has already started, so "the user came back", "the battery got tight" and
/// "the toggle went off" have to be re-evaluated INSIDE a running pass, per unit. `Conditions` is
/// therefore exactly the set of signals that are cheap and synchronous to read, and the two facts that
/// only a start can be judged on are parameters of `shouldStart`.
///
/// `isPackInstalled` is a start-only fact for a measured reason: reading it is
/// `LanguageAvailability().status(from:to:)` at ~4.8 ms warm, and per-unit over a 1,294-unit pass that
/// is ~6 s of probing — the very waste the gate exists to prevent. A pack deleted mid-pass is already
/// handled: `SystemTranslator.translate` nils out and the run writes nothing.
public enum IdleTranslationPolicy {
  /// How long the user must have been away before a pass may start, and below which a running pass
  /// yields. Judgement, not measurement — there is nothing to measure it against until a pass has been
  /// observed. See the spec's "Deliberately left open".
  public static let idleThreshold: TimeInterval = 300

  /// The machine's cheap, synchronously-readable state.
  public struct Conditions: Sendable {
    /// The Settings toggle. Part of the mid-run predicate too, so switching it off stops a pass.
    public let isEnabled: Bool
    /// The resolved translation target; `TranslationTarget.off` means the feature is disabled.
    public let language: String
    /// Seconds since the last human input.
    public let idleSeconds: TimeInterval
    public let isLowPower: Bool
    public let thermalState: ProcessInfo.ThermalState

    public init(isEnabled: Bool, language: String, idleSeconds: TimeInterval,
                isLowPower: Bool, thermalState: ProcessInfo.ThermalState) {
      self.isEnabled = isEnabled
      self.language = language
      self.idleSeconds = idleSeconds
      self.isLowPower = isLowPower
      self.thermalState = thermalState
    }
  }

  /// Whether a pass that is already running should translate another unit.
  public static func shouldContinue(_ conditions: Conditions) -> Bool {
    conditions.isEnabled
      && conditions.language != TranslationTarget.off
      && conditions.idleSeconds >= idleThreshold
      && !conditions.isLowPower
      && conditions.thermalState != .serious
      && conditions.thermalState != .critical
  }

  /// Whether a new pass may start. Expressed THROUGH `shouldContinue` rather than beside it, so the
  /// shared half cannot be edited in one place and not the other.
  public static func shouldStart(_ conditions: Conditions,
                                 isPackInstalled: Bool, isRunInFlight: Bool) -> Bool {
    shouldContinue(conditions) && isPackInstalled && !isRunInFlight
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test FILTER=IdleTranslationPolicy`
Expected: PASS, 7 tests.

If the compiler rejects `ProcessInfo.ThermalState` in a `Sendable` struct under Swift 6 strict concurrency (it is an `Int`-backed imported enum and should be implicitly `Sendable`), replace that property with `isThermallyConstrained: Bool`, move the `.serious`/`.critical` comparison to the call site in Task 3, and change the three thermal `#expect`s to pass `isThermallyConstrained:` instead. Do not add `@unchecked Sendable`.

- [ ] **Step 5: Run the mutations — do not skip this**

This repo has shipped vacuous tests twice and caught them only by running the mutation. For **each** of the four clauses below: make the edit, run `make test FILTER=IdleTranslationPolicy`, confirm the named test FAILS, then revert.

| Mutation | Must fail |
|---|---|
| Delete `&& conditions.idleSeconds >= idleThreshold` | `refusesWhileTheUserIsActive` |
| Delete `&& isPackInstalled` | `refusesWithoutAnInstalledLanguagePack` |
| Delete `&& !isRunInFlight` | `refusesWhileAnotherRunHoldsTheSlot` |
| Delete `&& !conditions.isLowPower` | `refusesWhenThePowerBudgetIsTight` |

If any mutation leaves the suite green, the test is vacuous — fix the test, not the implementation.

- [ ] **Step 6: Lint and commit**

```bash
make lint
git add Sources/PensieveKit/Translation/IdleTranslationPolicy.swift Tests/PensieveKitTests/IdleTranslationPolicyTests.swift
git commit -F - <<'EOF'
feat(kit): judge whether now is a good moment to translate

A pure policy over injected readings, split in two: a start predicate
and a keep-going predicate that a running pass re-evaluates per unit,
because NSBackgroundActivityScheduler cannot interrupt a block it has
already started.

isPackInstalled is a start-only fact on measured grounds -- the reading
is an async availability probe at ~4.8 ms, and per-unit over a
1,294-unit pass that is ~6 s of probing, which is the waste the gate
exists to prevent. It is also the one condition the manual path never
needed: that guard lives in the view, on the button's disabled state,
and an automatic caller does not pass through the view.

All four clauses mutation-checked.
EOF
```

---

### Task 2: The Settings toggle

**Files:**
- Modify: `Sources/PensieveApp/AppDefaults.swift`
- Modify: `Sources/PensieveApp/Settings/TranslationSettingsTab.swift:135-152`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `AppDefaults.idleTranslationEnabledKey: String` and `AppDefaults.idleTranslationEnabled: Bool`. Task 3 reads the latter.

This task ships a toggle that stores a preference nothing reads yet. That is deliberate: it is independently reviewable, and it means Task 3's policy has a real source for `isEnabled` rather than a placeholder.

- [ ] **Step 1: Add the key and the non-View accessor**

In `Sources/PensieveApp/AppDefaults.swift`, add the key beside the existing three:

```swift
  static let idleTranslationEnabledKey = "app.idleTranslationEnabled"
```

and the accessor after `backgroundSyncEnabled`:

```swift
  /// Idle translation is ON by default (matching the `@AppStorage(...) = true` in the view). The
  /// policy reads this accessor, not `UserDefaults.bool` directly — which alone reads false when
  /// unset and would disagree with the toggle before Settings has ever been opened, leaving the
  /// feature silently off for exactly the users who never went looking for it.
  static var idleTranslationEnabled: Bool {
    UserDefaults.standard.object(forKey: idleTranslationEnabledKey) == nil
      ? true : UserDefaults.standard.bool(forKey: idleTranslationEnabledKey)
  }
```

`UserDefaults.standard` and not `PensieveDefaults.shared()`: this setting is app-only. The CLI and the launchd agent never translate, so nothing cross-process reads it — the same reasoning that puts `narrationEnabled` and `backgroundSyncEnabled` here.

- [ ] **Step 2: Add the toggle to the Translation tab**

In `TranslationSettingsTab`, add the storage property beside `translationTarget` (around line 63):

```swift
  @AppStorage(AppDefaults.idleTranslationEnabledKey) private var idleTranslationEnabled = true
```

Then in `settings`, inside the existing `if !isOff { if #available(macOS 26, *) { … } }` branch, add the toggle **after** `coverageRow`:

```swift
      if #available(macOS 26, *) {
        packStatus
        coverageRow
        Toggle("Translate automatically when idle", isOn: $idleTranslationEnabled)
        Text("Runs after the Mac has been unused for a few minutes, and pauses in Low Power Mode or under heavy load.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
```

It sits under the same availability branch as the rest, and only when a target is selected: a toggle for automating a feature that is off would be inert.

- [ ] **Step 3: Add the two catalog keys by hand**

`xcodebuild` does **not** populate `Localizable.xcstrings` — that is IDE-only. Add both entries to the `"strings"` object in `Sources/PensieveApp/Localizable.xcstrings`, with the key matching the Swift literal **exactly** (a mismatch falls back to English silently):

```json
    "Translate automatically when idle" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Automatisch bei Inaktivität übersetzen"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Translate automatically when idle"
          }
        }
      }
    },
    "Runs after the Mac has been unused for a few minutes, and pauses in Low Power Mode or under heavy load." : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Läuft, wenn der Mac einige Minuten unbenutzt war, und pausiert im Stromsparmodus oder bei hoher Auslastung."
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Runs after the Mac has been unused for a few minutes, and pauses in Low Power Mode or under heavy load."
          }
        }
      }
    },
```

German is impersonal/infinitive per the house style ("Automatisch … übersetzen", not "Übersetze automatisch"). "Low Power Mode" is rendered as the macOS German term **Stromsparmodus**.

- [ ] **Step 4: Build and verify the catalog compiled**

```bash
make build
plutil -p .build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -i "Inaktivität\|Stromsparmodus"
```

Expected: `make build` succeeds; both German strings appear in the output. If they do not, the key does not match its Swift literal character-for-character — fix the JSON key, not the Swift string.

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add Sources/PensieveApp/AppDefaults.swift Sources/PensieveApp/Settings/TranslationSettingsTab.swift Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(app): offer to translate automatically when idle

The toggle and its preference, ahead of anything reading them, so the
policy lands next to a real source for isEnabled rather than a stub.

The non-View accessor repeats the object(forKey:) == nil dance the two
existing toggles use: UserDefaults.bool alone reads false when unset,
which would leave the feature off for precisely the users who never
opened Settings to find it.
EOF
```

---

### Task 3: `IdleSensors` and the pass

**Files:**
- Create: `Sources/PensieveApp/IdleSensors.swift`
- Modify: `Sources/PensieveApp/AppModel.swift:138-151` (the `TranslationBackfillRun` struct)
- Modify: `Sources/PensieveApp/AppModel+Translation.swift:67-100` (`startTranslationBackfill`) and append `runIdleTranslationPass`

**Interfaces:**
- Consumes: `IdleTranslationPolicy.Conditions`, `.shouldContinue(_:)`, `.shouldStart(_:isPackInstalled:isRunInFlight:)` (Task 1); `AppDefaults.idleTranslationEnabled` (Task 2). Existing: `AppModel.measureTranslationCoverage()`, `AppModel.startTranslationBackfill()`, `AppModel.cancelTranslationBackfill()`, `AppModel.translationBackfillRun`, `TranslationTarget.resolved()`, `TranslationTarget.sourceLanguage`.
- Produces: `IdleSensors.conditions(language:) -> IdleTranslationPolicy.Conditions`, `IdleSensors.isPackInstalled(language:) async -> Bool`, `AppModel.runIdleTranslationPass() async -> Bool`, `AppModel.TranslationBackfillRun.Trigger`. Task 4 calls `runIdleTranslationPass()`.

`runIdleTranslationPass` has no caller until Task 4 — that is the wiring step.

- [ ] **Step 1: Create the sensors**

Create `Sources/PensieveApp/IdleSensors.swift`:

```swift
import CoreGraphics
import Foundation
import Translation
import PensieveKit

/// The machine readings `IdleTranslationPolicy` judges, in one place.
///
/// One place because two callers need them and they must not drift: the scheduler decides whether to
/// START a pass, and the pass itself decides per unit whether to KEEP GOING. Two copies of "how idle
/// is idle" is how those two answers stop agreeing.
enum IdleSensors {
  /// Seconds since the last human input.
  ///
  /// `.combinedSessionState` counts synthesized events alongside hardware ones, which is the honest
  /// reading of "is a human doing something" — an automation driving the machine is not idleness.
  /// The `~0` event type is `kCGAnyInputEventType`, which Foundation does not expose as a symbol.
  ///
  /// Deliberately NOT an event tap: this call needs no entitlement and raises no Accessibility
  /// prompt. It also covers screen lock, screensaver and display sleep for free, because idle time
  /// simply keeps climbing through all three.
  static var idleSeconds: TimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                            eventType: CGEventType(rawValue: ~0)!)
  }

  /// Everything the policy can read synchronously and cheaply.
  static func conditions(language: String) -> IdleTranslationPolicy.Conditions {
    let processInfo = ProcessInfo.processInfo
    return IdleTranslationPolicy.Conditions(isEnabled: AppDefaults.idleTranslationEnabled,
                                            language: language,
                                            idleSeconds: idleSeconds,
                                            isLowPower: processInfo.isLowPowerModeEnabled,
                                            thermalState: processInfo.thermalState)
  }

  /// The one reading that is not cheap — hence a start-only fact, never re-probed per unit.
  ///
  /// `LanguageAvailability` is macOS 15+ (only `TranslationSession(installedSource:)` is 26+) and the
  /// deployment target is 26.0, so this needs no availability annotation — the same reasoning
  /// `TranslationLanguageCatalog` records.
  static func isPackInstalled(language: String) async -> Bool {
    guard language != TranslationTarget.off else { return false }
    let status = await LanguageAvailability().status(
      from: Locale.Language(identifier: TranslationTarget.sourceLanguage),
      to: Locale.Language(identifier: language))
    return status == .installed
  }
}
```

If Swift 6 strict concurrency objects to `LanguageAvailability` here (the `Translation` framework's types are un-audited for `Sendable`), add the file-scoped `@preconcurrency import Translation` that `TranslationSettingsTab.swift:4` already uses for exactly this reason — and keep it file-scoped.

- [ ] **Step 2: Move `TranslationBackfillRun`, then tag the run with its trigger**

`AppModel.swift` is at **389** lines against a hard 400 (`swiftlint --strict`, which CI runs). This task and Task 4 together add ~12, which crosses it. Rather than discover that at lint time and trim comments under pressure, move the type out first — it belongs beside the code that builds it anyway, which is the same argument that moved `commitNewNode`/`updateNode` into `AppModel+Organizing.swift`.

**Cut** the entire `struct TranslationBackfillRun { … }` declaration (`AppModel.swift:132-150`, including its doc comment) and **paste** it at the top of the existing `extension AppModel` in `AppModel+Translation.swift`. A nested type may be declared in an extension; only the *stored property* must stay behind. Leave `var translationBackfillRun: TranslationBackfillRun?` and its doc comment in `AppModel.swift` — a stored property cannot move to an extension.

Then, in the moved struct, add the nested type and the property:

```swift
  struct TranslationBackfillRun {
    /// What started this run. A manual run must never be cancelled for "the user came back" — they
    /// pressed the button — so the per-unit yield is conditional on this.
    enum Trigger: Sendable { case manual, automatic }
    /// `Task.detached` deliberately — see `startTranslationBackfill`.
    let task: Task<Int, Never>
```

and, after `let language: String`:

```swift
    let trigger: Trigger
```

Do not rename it or change its other members: `TranslationSettingsTab` reads `run.language`, `run.done` and `run.total`, and `AppModel.swift` still names the type in the stored property's declaration.

- [ ] **Step 3: Take the trigger, and yield the machine back**

In `Sources/PensieveApp/AppModel+Translation.swift`, change the signature:

```swift
  func startTranslationBackfill(trigger: TranslationBackfillRun.Trigger = .manual) {
```

The default keeps every existing call site (`TranslationSettingsTab.swift:239`) unchanged.

Replace the `report` closure with:

```swift
    let report: @Sendable (Int, Int) -> Void = { [weak self] done, _ in
      Task { @MainActor in
        guard let self else { return }
        self.translationBackfillRun?.done = done
        // Read the trigger off the LIVE run rather than the captured parameter, for the same reason
        // `done` is written through the optional: a callback that arrives after the run it belongs to
        // has gone must be a no-op, not an act on whatever is there now.
        guard self.translationBackfillRun?.trigger == .automatic,
              !IdleTranslationPolicy.shouldContinue(IdleSensors.conditions(language: language))
        else { return }
        AppLog.app.info("Idle translation yielding after \(done, privacy: .public) unit(s)")
        self.cancelTranslationBackfill()
      }
    }
```

and pass the trigger when building the run:

```swift
    translationBackfillRun = .init(task: work, language: language, trigger: trigger,
                                   done: 0, total: missing.count)
```

This closure is the entire interruption mechanism — no second timer, no polling task. `TranslationBackfill.run` checks `Task.isCancelled` before each unit, so a yield stops at the next unit boundary with everything already written intact. Resumable-by-construction is why stopping early costs nothing: the next idle window pays only for what is still missing.

- [ ] **Step 4: Add the pass**

Append to the same extension in `AppModel+Translation.swift`:

```swift
  /// Translate whatever is missing, unasked, because the Mac is idle.
  ///
  /// Deliberately a composition of two methods that already exist rather than a second execution
  /// path. It claims the SAME `translationBackfillRun` slot the button does, which is what makes the
  /// Settings progress row, its Stop button, the disabled state of "Translate remaining" and
  /// cancellation on a language switch all work for an automatic run with no new UI at all.
  ///
  /// `measureTranslationCoverage()` is reused rather than reimplemented because it produces exactly
  /// what is needed — a `TranslationCoverage` carrying its language and its `missing` work list —
  /// and because measuring through the one method keeps the coverage Settings would show and the
  /// coverage this acts on the same value. The await between measuring and starting is safe:
  /// `startTranslationBackfill` re-checks every precondition after it.
  ///
  /// - Returns: whether a pass actually started, so the scheduler can distinguish work done from a
  ///   refusal and report `.finished` versus `.deferred`.
  @discardableResult
  func runIdleTranslationPass() async -> Bool {
    let language = TranslationTarget.resolved()
    let conditions = IdleSensors.conditions(language: language)
    // The cheap half first, purely to avoid paying for the availability probe below on a machine the
    // user is actively using. `shouldStart` re-checks it; this guard is an optimization, not a rule.
    guard IdleTranslationPolicy.shouldContinue(conditions) else { return false }
    let isPackInstalled = await IdleSensors.isPackInstalled(language: language)
    guard IdleTranslationPolicy.shouldStart(conditions, isPackInstalled: isPackInstalled,
                                            isRunInFlight: translationBackfillRun != nil)
    else { return false }

    await measureTranslationCoverage()
    startTranslationBackfill(trigger: .automatic)
    // Not `true`: `startTranslationBackfill` still refuses a coverage with nothing missing, which is
    // the common case once the corpus has caught up.
    let started = translationBackfillRun != nil
    if started { AppLog.app.info("Idle translation pass started") }
    return started
  }
```

- [ ] **Step 5: Build, and check the line budget**

```bash
wc -l Sources/PensieveApp/AppModel.swift
make build
```

Expected: `AppModel.swift` is now around **370** lines — down from 389, because Step 2 moved ~19 lines of type declaration out and this task adds nothing else to that file. The build succeeds. If the count is still near 400, Step 2's move did not happen; do it before continuing, because Task 4 adds ~7 more.

- [ ] **Step 6: Lint and commit**

```bash
make lint
git add Sources/PensieveApp/IdleSensors.swift Sources/PensieveApp/AppModel.swift Sources/PensieveApp/AppModel+Translation.swift
git commit -F - <<'EOF'
feat(app): translate the backlog while the Mac sits idle

The pass composes measureTranslationCoverage and
startTranslationBackfill rather than forking a second execution path,
and claims the same in-flight slot the button does -- which is why the
progress row, its Stop button, the disabled "Translate remaining" and
cancellation on a language switch all work for an automatic run with
no new UI.

Interruption is the progress callback that already existed, now
re-evaluating the policy per unit for automatic runs only. It reads
the trigger off the live run rather than the captured parameter, for
the same reason done is written through the optional: a callback
outliving its run must be a no-op, not an act on its successor.

Nothing calls the pass yet; the schedule is next.
EOF
```

---

### Task 4: The schedule

**Files:**
- Create: `Sources/PensieveApp/TranslationActivityScheduler.swift`
- Modify: `Sources/PensieveApp/AppModel.swift` (one property near `:72-73`; installation at the end of `start()`, after the `UserDefaults.didChangeNotification` observer at `:253-256`)

**Interfaces:**
- Consumes: `AppModel.runIdleTranslationPass() async -> Bool` (Task 3).
- Produces: `TranslationActivityScheduler(model:)` and `.start()`. Nothing consumes these.

- [ ] **Step 1: Write the scheduler**

Create `Sources/PensieveApp/TranslationActivityScheduler.swift`:

```swift
import Foundation

/// Asks the system for a good moment to translate, through Foundation's own primitive for
/// discretionary maintenance work.
///
/// `NSBackgroundActivityScheduler` already defers on battery, thermal pressure and Low Power Mode.
/// `IdleTranslationPolicy` re-checks those anyway, because the scheduler's notion of "optimal" is
/// about the MACHINE — it holds no opinion about our toggle, our language setting, our in-flight run,
/// or whether a human is at the keyboard.
///
/// App-lifetime, like the liveness watchers: it is created once in `AppModel.start()` and never
/// invalidated, because this `AppModel` never deinits.
@MainActor
final class TranslationActivityScheduler {
  /// Half-hourly with a generous tolerance, so the system can fold this into a wake it was doing
  /// anyway rather than causing one. Both numbers are judgement, not measurement — see the spec's
  /// "Deliberately left open".
  private static let interval: TimeInterval = 30 * 60
  private static let tolerance: TimeInterval = 10 * 60

  private let scheduler = NSBackgroundActivityScheduler(identifier: "me.mazetti.pensieve.translation")
  private weak var model: AppModel?

  init(model: AppModel) {
    self.model = model
    scheduler.repeats = true
    scheduler.interval = Self.interval
    scheduler.tolerance = Self.tolerance
    scheduler.qualityOfService = .background
  }

  func start() {
    scheduler.schedule { [weak model] completion in
      Task { @MainActor in
        guard let model else { return completion(.finished) }
        // Deliberately awaits only the decision and the coverage measurement, NOT the translation
        // itself: `startTranslationBackfill` owns the run and its completion, as it does for the
        // button. Holding this handler open for a pass of unmeasured length would be a promise about
        // wall time this design cannot make, and it buys nothing — a second firing landing mid-run is
        // already refused by the in-flight check.
        let started = await model.runIdleTranslationPass()
        // `.deferred` so a refusal is not recorded as work done. When the system re-fires after one is
        // its business; nothing here depends on the timing, and another interval's wait is acceptable
        // for maintenance work by definition.
        completion(started ? .finished : .deferred)
      }
    }
  }
}
```

If Swift 6 strict concurrency rejects capturing `completion` inside the `Task` (the `CompletionHandler` typealias is not `Sendable`-annotated), add `nonisolated(unsafe) let completion = completion` as the first line of the `schedule` block and capture that. It is safe here — the handler is called exactly once, from one task. Do not restructure the block to call `completion` synchronously before the work; that would report a refusal as `.finished`.

- [ ] **Step 2: Hold and install it**

In `Sources/PensieveApp/AppModel.swift`, add the property beside the other watchers (near `:72-73`):

```swift
  @ObservationIgnored private var translationActivityScheduler: TranslationActivityScheduler?
```

and install it at the end of `start()`, after the `UserDefaults.didChangeNotification` observer:

```swift
    // Idle translation. App-lifetime like the watchers above: the corpus grows with every sync, so
    // this is a standing job, not a launch-time one.
    let translationScheduler = TranslationActivityScheduler(model: self)
    translationScheduler.start()
    translationActivityScheduler = translationScheduler
    AppLog.app.info("Idle translation scheduled")
```

- [ ] **Step 3: Build and smoke**

```bash
make build
make smoke
```

Expected: both succeed. Note honestly what this proves and does not: `make smoke` launches the inner binary and kills it, and does **not** render a view body, so it exercises `start()` but not the toggle, and no scheduled firing occurs inside its lifetime. The scheduler, the pass and the toggle have no automated coverage — that is stated in the spec, not a gap this task can close.

- [ ] **Step 4: Full check and commit**

```bash
make all
git add Sources/PensieveApp/TranslationActivityScheduler.swift Sources/PensieveApp/AppModel.swift
git commit -F - <<'EOF'
feat(app): schedule the idle translation pass

NSBackgroundActivityScheduler is Foundation's own primitive for
discretionary maintenance, so it sets the cadence and already defers on
battery, thermal pressure and Low Power Mode. The policy re-checks
those regardless: the scheduler's "optimal" is about the machine and
holds no opinion about our toggle, our language, our in-flight run, or
whether a human is at the keyboard.

The block awaits the decision, not the translation. A refusal reports
.deferred so it is not recorded as work done.
EOF
```

---

## Verification

`make all` (lint + test + build + embedded-CLI smoke) must pass at the end of Task 4. Expected test count: **+7** over the baseline at `601ed12`.

**What has NOT executed, stated plainly:** the app target has no unit tests and `make smoke` renders no view body, so `IdleSensors`, `TranslationActivityScheduler`, `runIdleTranslationPass`, the per-unit yield and the toggle are verified by the compiler and by inspection only. Only `IdleTranslationPolicy` has real coverage. Do not report the feature as verified.

## Human-verify carries

These need the installed app (`make run` — **never Spotlight**, which picks between stale registrations), a real store, and an installed language pack.

1. **The whole point.** Toggle on, pack installed, leave the Mac untouched 30+ min, then open Settings ▸ Translation: coverage has climbed on its own.
2. **Catch one running.** The progress row renders with its Stop button, and "Translate remaining" is disabled.
3. **Yielding.** Touch the keyboard mid-pass — it stops within a unit, and coverage keeps everything already written. `log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 1h` shows "Idle translation yielding after N unit(s)".
4. **Both off-switches.** Toggle off mid-pass → stops. Switch language mid-pass → stops (existing `.onChange`).
5. **No pack, no waste.** Select a target whose pack is *not* installed, leave the Mac idle, and confirm the log shows no pass starting and no repeated nil'd work.
6. **German in situ** for the toggle and its footer.
7. **Time it.** Note the wall clock of the first full pass — that number closes the still-open ETA item (`backlog.md:1310`) and is the revisit trigger for both scheduler constants.
