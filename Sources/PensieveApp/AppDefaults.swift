import Foundation
import PensieveKit

/// UserDefaults keys shared between an `@AppStorage` binding in a View and a plain
/// `UserDefaults` read elsewhere (e.g. the AppDelegate, which can't use `@AppStorage`), so
/// the two can't drift. Mirrors the existing FocusFilterDefaults pattern.
enum AppDefaults {
  static let hideDockIconKey = "app.hideDockIcon"
  static let narrationEnabledKey = "app.narrationEnabled"
  static let backgroundSyncEnabledKey = "app.backgroundSyncEnabled"
  static let idleTranslationEnabledKey = "app.idleTranslationEnabled"

  /// Set by Settings when the user confirms a move; read at the NEXT launch, before any store is
  /// opened. Cleared once the relocation finishes, succeeds or fails — a key that survived a
  /// failure would retry the move on every launch forever.
  static let pendingRelocationDestinationKey = "pendingRelocationDestination"

  /// Narration is ON by default (matching the `@AppStorage(...) = true` in the views). Non-View
  /// readers (AppModel) must honor the same default — `UserDefaults.bool` alone reads false when
  /// unset, which would disagree with the views before Settings is ever opened.
  static var narrationEnabled: Bool {
    UserDefaults.standard.object(forKey: narrationEnabledKey) == nil
      ? true : UserDefaults.standard.bool(forKey: narrationEnabledKey)
  }

  /// Background sync is ON by default (preserving the always-syncing daemon behavior). Non-View
  /// readers (AppDelegate) must honor the same default as the Settings toggle.
  static var backgroundSyncEnabled: Bool {
    UserDefaults.standard.object(forKey: backgroundSyncEnabledKey) == nil
      ? true : UserDefaults.standard.bool(forKey: backgroundSyncEnabledKey)
  }

  /// Idle translation is ON by default (matching the `@AppStorage(...) = true` in the view). The
  /// policy reads this accessor, not `UserDefaults.bool` directly — which alone reads false when
  /// unset and would disagree with the toggle before Settings has ever been opened, leaving the
  /// feature silently off for exactly the users who never went looking for it.
  static var idleTranslationEnabled: Bool {
    UserDefaults.standard.object(forKey: idleTranslationEnabledKey) == nil
      ? true : UserDefaults.standard.bool(forKey: idleTranslationEnabledKey)
  }
}
