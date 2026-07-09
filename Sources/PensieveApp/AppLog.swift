import os

/// App-target logger (separate from PensieveKit's `Log` enum which is internal to the library).
enum AppLog {
  static let app = Logger(subsystem: "me.mazetti.pensieve", category: "app")
}
