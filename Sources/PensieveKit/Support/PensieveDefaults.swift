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

  /// Written by the app's Focus filter on Focus activation, read by every process that must agree
  /// with what the window shows — including the sync agent, which publishes the widget digest.
  /// Lives here rather than in the app target for that reason: the agent cannot see app-target types.
  public static let activeFocusContextKey = "pensieve.activeFocusContext"

  /// The app's defaults domain, read from the CLI/daemon. Falls back to `.standard` if the suite
  /// can't be opened (never nil).
  ///
  /// A process reading ITS OWN defaults domain must use `.standard` — Apple documents
  /// `UserDefaults(suiteName:)` as not for accessing the app's own domain. Without this guard the
  /// app could write the custom-support-root key through `.standard` and fail to read it back
  /// through the suite instance, leaving a relocation invisible to the very process that performed
  /// it. The CLI and the launchd helper have different bundle identifiers and are unaffected.
  ///
  /// `bundleIdentifier` is injectable, separated from reading `Bundle.main` for the same reason
  /// `supportDirectory(customRoot:)` and `indexURL(named:storeOverride:support:)` are: the real
  /// source is process-global (the running binary's own Info.plist), which under `swift test` can
  /// never equal `appDomain` — only the built app target's Info.plist does — so a test that only
  /// ever called the zero-argument form could never exercise the `.standard` branch at all.
  public static func shared(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> UserDefaults {
    if bundleIdentifier == appDomain { return .standard }
    return UserDefaults(suiteName: appDomain) ?? .standard
  }

  /// True when a custom support root has been persisted. Pulled out so every reader of
  /// `customSupportRootKey` (the Advanced tab's status line, the Support Folder inspector's
  /// picker) shares one rule instead of each restating "is it non-empty" — two copies of that
  /// check drifting apart is exactly the defect class this project keeps finding elsewhere.
  ///
  /// Delegates to `PensievePaths.supportDirectory(customRoot:)` rather than restating its own
  /// notion of "non-empty" — that resolver trims whitespace and requires an absolute path before
  /// honouring a stored value, so a naive `!raw.isEmpty` (or even `!raw.isEmpty && raw.hasPrefix
  /// ("/")`, which still misses a leading-whitespace value the resolver trims first) would read
  /// "Custom" in the UI for a value the resolver silently treats as absent — the two paths
  /// disagreeing while looking like they agree. Comparing resolved directories instead makes that
  /// unrepresentable by construction.
  public static func isCustomSupportRoot(_ raw: String) -> Bool {
    PensievePaths.supportDirectory(customRoot: raw) != PensievePaths.defaultSupportDirectory()
  }
}
