import AppKit

/// The standard macOS About panel — the first-party primitive, not a hand-built window.
enum AppInfo {
  /// `NSApplication.shared` is main-actor isolated; the only caller is a `.commands` `Button`, which
  /// is already on the main actor.
  @MainActor
  static func showAboutPanel() {
    let credits = NSAttributedString(
      string: String(localized: "A personal tool for reloading context across parallel projects. Not a product."),
      attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        .foregroundColor: NSColor.secondaryLabelColor,
      ])

    // Version/build come from the bundle and are NEVER localized.
    let bundleInfo = Bundle.main.infoDictionary
    let version = bundleInfo?["CFBundleShortVersionString"] as? String ?? ""
    let build = bundleInfo?["CFBundleVersion"] as? String ?? ""

    NSApplication.shared.orderFrontStandardAboutPanel(options: [
      .applicationName: "Pensieve",
      .applicationVersion: version,
      .version: build,
      .credits: credits,
    ])
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}
