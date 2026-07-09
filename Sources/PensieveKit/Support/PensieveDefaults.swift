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

  /// The app's defaults domain, read from the CLI/daemon. Falls back to `.standard` if the suite
  /// can't be opened (never nil). The app itself uses `.standard` directly (its own domain).
  public static func shared() -> UserDefaults { UserDefaults(suiteName: appDomain) ?? .standard }
}
