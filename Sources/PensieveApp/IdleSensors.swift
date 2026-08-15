// Sources/PensieveApp/IdleSensors.swift
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
