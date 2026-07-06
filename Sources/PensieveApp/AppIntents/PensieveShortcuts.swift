import AppIntents

/// One declaration surfaces each action in Siri, the Shortcuts app, and as a Spotlight action.
/// Keeping OpenNodeIntent here is load-bearing: an IndexedEntity is only surfaced in Spotlight when
/// it is also referenced as an App Shortcut parameter. Do not drop it.
struct PensieveShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ShowPensieveListIntent(),
      phrases: [
        "Show my \(.applicationName) list",
        "What's next in \(.applicationName)",
        "Show my dormant projects in \(.applicationName)",
      ],
      shortTitle: "Show List",
      systemImageName: "list.bullet")
    AppShortcut(
      intent: OpenNodeIntent(),
      phrases: ["Open a node in \(.applicationName)"],
      shortTitle: "Open Node",
      systemImageName: "doc.text")
  }
}
