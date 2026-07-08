import Foundation

/// UserDefaults keys shared between an `@AppStorage` binding in a View and a plain
/// `UserDefaults` read elsewhere (e.g. the AppDelegate, which can't use `@AppStorage`), so
/// the two can't drift. Mirrors the existing FocusFilterDefaults pattern.
enum AppDefaults {
  static let hideDockIconKey = "app.hideDockIcon"
  static let narrationEnabledKey = "app.narrationEnabled"

  /// Narration is ON by default (matching the `@AppStorage(...) = true` in the views). Non-View
  /// readers (AppModel) must honor the same default — `UserDefaults.bool` alone reads false when
  /// unset, which would disagree with the views before Settings is ever opened.
  static var narrationEnabled: Bool {
    UserDefaults.standard.object(forKey: narrationEnabledKey) == nil
      ? true : UserDefaults.standard.bool(forKey: narrationEnabledKey)
  }
}
