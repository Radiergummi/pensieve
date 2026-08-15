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
