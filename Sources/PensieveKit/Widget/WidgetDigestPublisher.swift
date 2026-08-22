import Foundation
import SQLiteData

/// Writes the widget's view of "what's next" into the App Group container. Called from two places —
/// the sync agent (so the widget is correct with the app closed, which is most of its life) and the
/// app (so it is immediate while you are working) — but the digest is assembled ONCE, because a
/// second copy of the wire format is how the two would come to disagree.
public enum WidgetDigestPublisher {
  /// The assembly, over an already-selected queue. Both callers arrive here: the sync agent through
  /// the `database` form below, and the app with the very list `refresh()` just computed — the app
  /// re-deriving the ranking would put a whole-store scan (three statements per active node) back on
  /// the main actor for an answer already in hand.
  public static func publish(items: [NextItem], now: Date, activeContext: String,
                             to url: URL = PensievePaths.widgetDigestURL()) throws {
    let digest = WidgetDigest(
      schemaVersion: WidgetDigest.currentSchemaVersion,
      generatedAt: now,
      context: activeContext.isEmpty ? nil : activeContext,
      items: items.prefix(WidgetDigest.maximumItems).map {
        WidgetDigest.Item(nodeID: $0.project.id, name: $0.project.name,
                          openLooseEnds: $0.openLooseEnds)
      })

    try PensievePaths.ensureParentDirectory(of: url)
    // Atomic: a widget waking mid-write must never read a truncated file.
    try JSONEncoder().encode(digest).write(to: url, options: .atomic)
  }

  /// The database form, for callers with no queue in hand. Selection is `NextQueries.whatsNext`, so
  /// the widget answers the same question as SmartLists, MCP `whats_next` and `pensieve next` rather
  /// than a different one of its own.
  ///
  /// `activeContext` is injected rather than read from defaults inside, for the same reason
  /// `PensievePaths.supportDirectory(customRoot:)` splits the rule from reading the world: the real
  /// source is process-global shared state, and Swift Testing runs suites in parallel.
  public static func publish(database: any DatabaseReader,
                             now: Date = Date(),
                             activeContext: String,
                             to url: URL = PensievePaths.widgetDigestURL()) throws {
    try publish(items: NextQueries.whatsNext(database, now: now, context: activeContext),
                now: now, activeContext: activeContext, to: url)
  }

  /// The form the sync agent uses. A publish failure is logged and swallowed — it must never be able
  /// to break a sync pass, on the same principle that keeps the capture path sacred.
  ///
  /// `to:` defaults to the real App Group container but exists as a seam so tests never touch it —
  /// this project has previously had a smoke test wipe a live search index by writing where a real
  /// caller writes; a destination parameter is how that mistake is made impossible here.
  public static func publishQuietly(database: any DatabaseReader,
                                    to url: URL = PensievePaths.widgetDigestURL()) {
    let activeContext = PensieveDefaults.shared()
      .string(forKey: PensieveDefaults.activeFocusContextKey) ?? ""
    quietly { try publish(database: database, now: Date(), activeContext: activeContext, to: url) }
  }

  /// The form the app uses: its own `activeFocusContext` and its own already-filtered queue, never
  /// the defaults domain — the app is the authority on which context is active, so re-reading the
  /// key it just wrote would be a second reader of the same state.
  public static func publishQuietly(items: [NextItem], now: Date = Date(), activeContext: String,
                                    to url: URL = PensievePaths.widgetDigestURL()) {
    quietly { try publish(items: items, now: now, activeContext: activeContext, to: url) }
  }

  private static func quietly(_ body: () throws -> Void) {
    do { try body() } catch {
      Log.widget.error("Widget digest publish failed: \(error, privacy: .public)")
    }
  }
}
