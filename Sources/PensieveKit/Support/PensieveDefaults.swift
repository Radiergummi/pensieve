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
  public static let semanticSearchKey = "app.semanticSearch"

  /// The app's defaults domain, read from the CLI/daemon. Falls back to `.standard` if the suite
  /// can't be opened (never nil). The app itself uses `.standard` directly (its own domain).
  public static func shared() -> UserDefaults { UserDefaults(suiteName: appDomain) ?? .standard }

  /// Semantic (vector) search is OFF by default. It is the experimental second engine now — BM25
  /// is the shipped retrieval path — and on this corpus the vector measured materially worse
  /// (P@1 0.250 vs 0.387). An explicitly stored `true` is still honored; only the unset default
  /// changed. Cross-process readers (the daemon, MCP) must agree with the app's @AppStorage default.
  public static func semanticSearchEnabled(_ defaults: UserDefaults = shared()) -> Bool {
    defaults.bool(forKey: semanticSearchKey)
  }
}
