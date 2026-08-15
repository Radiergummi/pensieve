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
