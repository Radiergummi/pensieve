import Foundation
import SQLiteData

/// Writes the widget's view of "what's next" into the App Group container. Called from two places —
/// the sync agent (so the widget is correct with the app closed, which is most of its life) and the
/// app (so it is immediate while you are working) — but implemented ONCE, because a second copy of
/// the ranking-plus-Focus rule is how the two would come to disagree.
public enum WidgetDigestPublisher {
  /// `activeContext` is injected rather than read from defaults inside, for the same reason
  /// `PensievePaths.supportDirectory(customRoot:)` splits the rule from reading the world: the real
  /// source is process-global shared state, and Swift Testing runs suites in parallel.
  public static func publish(database: any DatabaseReader,
                             now: Date = Date(),
                             activeContext: String,
                             to url: URL = PensievePaths.widgetDigestURL()) throws {
    var ranked = try NextQueries.ranked(database, now: now)

    // Reuse the Focus predicate rather than restating it. Empty context = no Focus active.
    if !activeContext.isEmpty {
      let nodes = try database.read { database in try Node.fetchAll(database) }
      let visible = NodeContextResolver.visibleNodeIDs(for: activeContext, in: nodes)
      ranked = ranked.filter { visible.contains($0.project.id) }
    }

    let items = ranked.prefix(WidgetDigest.maximumItems).map {
      WidgetDigest.Item(nodeID: $0.project.id, name: $0.project.name,
                        openLooseEnds: $0.openLooseEnds,
                        lastActivityAt: $0.lastActivityAt, daysDormant: $0.daysDormant)
    }
    let digest = WidgetDigest(schemaVersion: WidgetDigest.currentSchemaVersion,
                              generatedAt: now,
                              context: activeContext.isEmpty ? nil : activeContext,
                              items: Array(items))

    try PensievePaths.ensureParentDirectory(of: url)
    // Atomic: a widget waking mid-write must never read a truncated file.
    try JSONEncoder().encode(digest).write(to: url, options: .atomic)
  }

  /// The form both callers use. A publish failure is logged and swallowed — it must never be able to
  /// break a sync pass or a UI refresh, on the same principle that keeps the capture path sacred.
  public static func publishQuietly(database: any DatabaseReader, now: Date = Date()) {
    let activeContext = PensieveDefaults.shared()
      .string(forKey: PensieveDefaults.activeFocusContextKey) ?? ""
    do {
      try publish(database: database, now: now, activeContext: activeContext)
    } catch {
      Log.widget.error("Widget digest publish failed: \(error, privacy: .public)")
    }
  }
}
