import Foundation
import PensieveKit

/// UserDefaults keys shared between an `@AppStorage` binding in a View and a plain
/// `UserDefaults` read elsewhere (e.g. the AppDelegate, which can't use `@AppStorage`), so
/// the two can't drift. Mirrors the existing FocusFilterDefaults pattern.
enum AppDefaults {
  static let hideDockIconKey = "app.hideDockIcon"
  static let narrationEnabledKey = "app.narrationEnabled"
  static let backgroundSyncEnabledKey = "app.backgroundSyncEnabled"

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

  /// Semantic search is ON by default (matching the @AppStorage default and the Kit reader).
  static var semanticSearchEnabled: Bool {
    UserDefaults.standard.object(forKey: PensieveDefaults.semanticSearchKey) == nil
      ? true : UserDefaults.standard.bool(forKey: PensieveDefaults.semanticSearchKey)
  }
}
