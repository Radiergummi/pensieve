import Foundation

/// The app's read-only view of "what's next", handed to a sandboxed widget through the App Group
/// container. A purpose-built DTO rather than a serialized `NextItem`: `NextItem` carries a whole
/// `Node` the widget has no use for, and pinning the wire format to a live model would turn every
/// model change into a widget-compatibility question.
public struct WidgetDigest: Codable, Equatable, Sendable {
  /// Bump when the shape changes. Catches only a NON-breaking widening (an older widget seeing a
  /// higher version number than its own) and refuses that file rather than mis-rendering it. A
  /// genuinely breaking change — a renamed or added-required field on `Item`, whose fields are all
  /// non-optional — fails to DECODE first, landing on `.noData` before this guard is ever reached;
  /// both outcomes are safe. In practice the appex ships inside the app bundle, so real version skew
  /// between publisher and reader is near-impossible.
  public static let currentSchemaVersion = 1
  /// Published regardless of family, so each family slices what it can show without a second
  /// publish path.
  public static let maximumItems = 8
  /// Derived from the agent's actual schedule rather than restating it: this was `20 * 60` with a
  /// comment reading "four missed 300 s agent passes", so changing `StartInterval` would have left
  /// the widget's idea of stale silently wrong in whichever direction the period moved.
  public static let stalenessThreshold: TimeInterval =
    BackgroundSyncSchedule.interval * Double(BackgroundSyncSchedule.missedPassesBeforeStale)

  public let schemaVersion: Int
  public let generatedAt: Date
  /// What the digest was filtered BY ("work"/"personal"/nil). Recorded, not just applied, so the
  /// widget can label the view and a mismatch is visible rather than silent.
  public let context: String?
  public let items: [Item]

  /// Exactly what the widget renders, and nothing else. `NextItem`'s other signals (dormancy, score,
  /// last activity) are deliberately absent: an unread field in a cross-process wire format reads to
  /// the next person as something they must keep working, and `daysDormant` in particular would be
  /// derivable from `generatedAt` anyway.
  public struct Item: Codable, Equatable, Sendable {
    public let nodeID: UUID
    /// Captured content — rendered verbatim, NEVER localized.
    public let name: String
    public let openLooseEnds: Int

    public init(nodeID: UUID, name: String, openLooseEnds: Int) {
      self.nodeID = nodeID; self.name = name; self.openLooseEnds = openLooseEnds
    }
  }

  public init(schemaVersion: Int, generatedAt: Date, context: String?, items: [Item]) {
    self.schemaVersion = schemaVersion; self.generatedAt = generatedAt
    self.context = context; self.items = items
  }

  /// Never throws into a timeline provider: an absent, unreadable or malformed file is `nil`, which
  /// `presentation` turns into `.noData`.
  public static func read(from url: URL = PensievePaths.widgetDigestURL()) -> WidgetDigest? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(WidgetDigest.self, from: data)
  }

  public static func presentation(for digest: WidgetDigest?, now: Date) -> WidgetPresentation {
    guard let digest else { return .noData }
    guard digest.schemaVersion <= currentSchemaVersion else { return .unsupportedSchema }
    if now.timeIntervalSince(digest.generatedAt) > stalenessThreshold {
      return .stale(digest.items, generatedAt: digest.generatedAt)
    }
    return .fresh(digest.items)
  }
}

/// What the widget should draw. Separated from the view because the widget target has no test
/// coverage at all — `PensieveKitTests` cannot reach it and `make uitest` drives the app.
public enum WidgetPresentation: Equatable, Sendable {
  case fresh([WidgetDigest.Item])
  case stale([WidgetDigest.Item], generatedAt: Date)
  case noData
  case unsupportedSchema
}
