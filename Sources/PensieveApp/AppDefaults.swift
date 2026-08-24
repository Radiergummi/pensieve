import Foundation
import PensieveKit

/// UserDefaults keys shared between an `@AppStorage` binding in a View and a plain
/// `UserDefaults` read elsewhere (e.g. the AppDelegate, which can't use `@AppStorage`), so
/// the two can't drift. Mirrors the existing `PensieveDefaults.activeFocusContextKey` pattern.
enum AppDefaults {
  static let hideDockIconKey = "app.hideDockIcon"
  static let narrationEnabledKey = "app.narrationEnabled"
  static let backgroundSyncEnabledKey = "app.backgroundSyncEnabled"
  static let idleTranslationEnabledKey = "app.idleTranslationEnabled"

  /// Set by Settings when the user confirms a move; read at the NEXT launch, before any store is
  /// opened. Cleared once the relocation finishes, succeeds or fails — a key that survived a
  /// failure would retry the move on every launch forever.
  static let pendingRelocationDestinationKey = "pendingRelocationDestination"

  // MARK: - Defaults for the unset case
  //
  // Each `@AppStorage` binding in a View MUST be declared with the constant below, and the non-View
  // accessor for the same key reads it too. `UserDefaults.bool` alone reads false when the key is
  // unset, which would disagree with a View defaulting to true before Settings is ever opened. This
  // used to be a comment — "matching the `@AppStorage(...) = true` in the views" — which named the
  // convention without enforcing it, so the KEYS were single-sourced and the VALUES were not.

  /// Narration is ON by default.
  static let narrationEnabledDefault = true
  /// Background sync is ON by default (preserving the always-syncing daemon behavior).
  static let backgroundSyncEnabledDefault = true
  /// Idle translation is ON by default — silently off would hit exactly the users who never went
  /// looking for it.
  static let idleTranslationEnabledDefault = true

  static var narrationEnabled: Bool {
    boolean(narrationEnabledKey, default: narrationEnabledDefault)
  }

  static var backgroundSyncEnabled: Bool {
    boolean(backgroundSyncEnabledKey, default: backgroundSyncEnabledDefault)
  }

  static var idleTranslationEnabled: Bool {
    boolean(idleTranslationEnabledKey, default: idleTranslationEnabledDefault)
  }

  private static func boolean(_ key: String, default fallback: Bool) -> Bool {
    UserDefaults.standard.object(forKey: key) == nil
      ? fallback : UserDefaults.standard.bool(forKey: key)
  }
}
