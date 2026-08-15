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
