import os

/// The widget extension's logger. It cannot reach the app target's `AppLog`, and PensieveKit's `Log`
/// is internal to the library, so the appex carries its own — same subsystem, its own category.
enum WidgetLog {
  static let widget = Logger(subsystem: "me.mazetti.pensieve", category: "widget")
}
