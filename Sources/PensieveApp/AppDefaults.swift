import Foundation

/// UserDefaults keys shared between an `@AppStorage` binding in a View and a plain
/// `UserDefaults` read elsewhere (e.g. the AppDelegate, which can't use `@AppStorage`), so
/// the two can't drift. Mirrors the existing FocusFilterDefaults pattern.
enum AppDefaults {
  static let hideDockIconKey = "app.hideDockIcon"
  static let narrationEnabledKey = "app.narrationEnabled"
}
