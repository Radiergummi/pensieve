import Foundation

/// The single source of truth for the shared UserDefaults surface, so the app (writer) and the
/// CLI/daemon (cross-process reader) can't drift on domain or key names. The app is not sandboxed,
/// so its defaults persist to ~/Library/Preferences/me.mazetti.pensieve.plist, served by the
/// per-user cfprefsd; a same-user CLI reads that domain via `shared()`.
public enum PensieveDefaults {
  public static let appDomain = "me.mazetti.pensieve"
  public static let llmProviderKey = "llmProvider"
  public static let cloudFlavorKey = "cloudFlavor"
  public static let cloudBaseURLKey = "cloudBaseURL"
  public static let cloudModelKey = "cloudModel"
  public static let translationTargetKey = "translationTarget"
  /// Absolute path of a user-chosen support folder. Absent = the default
  /// `~/Library/Application Support/Pensieve`. Written only by the app's relocator, read by every
  /// process that resolves a Pensieve path.
  public static let customSupportRootKey = "customSupportRoot"

  /// The app's defaults domain, read from the CLI/daemon. Falls back to `.standard` if the suite
  /// can't be opened (never nil).
  ///
  /// A process reading ITS OWN defaults domain must use `.standard` — Apple documents
  /// `UserDefaults(suiteName:)` as not for accessing the app's own domain. Without this guard the
  /// app could write the custom-support-root key through `.standard` and fail to read it back
  /// through the suite instance, leaving a relocation invisible to the very process that performed
  /// it. The CLI and the launchd helper have different bundle identifiers and are unaffected.
  public static func shared() -> UserDefaults {
    if Bundle.main.bundleIdentifier == appDomain { return .standard }
    return UserDefaults(suiteName: appDomain) ?? .standard
  }
}
