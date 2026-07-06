import Foundation

/// A `pensieve://` deep link — the foundational cross-surface entry point. Pure URL
/// parsing/serialization with no store access, so it is fully unit-tested. The menu-bar item is the
/// first consumer; later surfaces (widgets, Spotlight) reuse the same scheme.
///
/// Grammar: `pensieve://<host>[/<segment>]`
///   pensieve://briefing
///   pensieve://node/<uuid>
///   pensieve://smartlist/<whatsNext|dormant|recentlyActive>
public enum DeepLink: Equatable, Sendable {
  /// The three sidebar smart lists. Raw values match the app's `SmartListKind` raw values so the
  /// app-side bridge needs no hand-maintained string table.
  public enum SmartList: String, Equatable, Sendable {
    case whatsNext, dormant, recentlyActive
  }

  case briefing
  case node(UUID)
  case smartList(SmartList)

  public static let scheme = "pensieve"

  /// Parses a `pensieve://…` URL. Returns nil for any unknown/malformed form.
  public init?(url: URL) {
    guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
          comps.scheme == Self.scheme, let host = comps.host else { return nil }
    let segments = comps.path.split(separator: "/").map(String.init)
    switch host {
    case "briefing":
      guard segments.isEmpty else { return nil }
      self = .briefing
    case "node":
      guard segments.count == 1, let id = UUID(uuidString: segments[0]) else { return nil }
      self = .node(id)
    case "smartlist":
      guard segments.count == 1, let kind = SmartList(rawValue: segments[0]) else { return nil }
      self = .smartList(kind)
    default:
      return nil
    }
  }

  /// The canonical URL for this link. `DeepLink(url: link.url) == link` for every case.
  public var url: URL {
    var comps = URLComponents()
    comps.scheme = Self.scheme
    switch self {
    case .briefing:
      comps.host = "briefing"
    case .node(let id):
      comps.host = "node"
      comps.path = "/\(id.uuidString)"
    case .smartList(let kind):
      comps.host = "smartlist"
      comps.path = "/\(kind.rawValue)"
    }
    return comps.url!
  }
}
