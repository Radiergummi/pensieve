import os

/// Central logger namespace for PensieveKit. One static `Logger` per category, all sharing the
/// app's bundle-identifier subsystem. Internal visibility — callers use `Log.sync.info(...)` etc.
enum Log {
  static let sync       = Logger(subsystem: "me.mazetti.pensieve", category: "sync")
  static let extraction = Logger(subsystem: "me.mazetti.pensieve", category: "extraction")
  static let llm        = Logger(subsystem: "me.mazetti.pensieve", category: "llm")
  static let ingest     = Logger(subsystem: "me.mazetti.pensieve", category: "ingest")
  static let discovery  = Logger(subsystem: "me.mazetti.pensieve", category: "discovery")
  static let semantic   = Logger(subsystem: "me.mazetti.pensieve", category: "semantic")
  static let search     = Logger(subsystem: "me.mazetti.pensieve", category: "search")
  static let widget     = Logger(subsystem: "me.mazetti.pensieve", category: "widget")
}
