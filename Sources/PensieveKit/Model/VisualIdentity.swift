import Foundation

/// A node's or source's icon, stored as a string with a scheme (`"sf:<symbol>"` / `"emoji:<x>"`).
/// Kit stays SwiftUI-free — the app renders `.sfSymbol` as an `Image(systemName:)` and `.emoji`
/// as `Text`.
public enum AppearanceIcon: Equatable, Sendable {
  case sfSymbol(String)
  case emoji(String)

  /// Parse a stored icon string. Returns nil for empty or malformed input (the caller then falls
  /// back to the kind default).
  public static func parse(_ raw: String) -> AppearanceIcon? {
    if raw.hasPrefix("sf:") {
      let s = String(raw.dropFirst(3)); return s.isEmpty ? nil : .sfSymbol(s)
    }
    if raw.hasPrefix("emoji:") {
      let e = String(raw.dropFirst(6)); return e.isEmpty ? nil : .emoji(e)
    }
    return nil
  }

  /// The canonical stored form, for writing back to `Node.icon`.
  public var storedString: String {
    switch self {
    case .sfSymbol(let s): return "sf:\(s)"
    case .emoji(let e): return "emoji:\(e)"
    }
  }
}

/// Default icon + palette color for a node kind. Icon is a stored string; colorTag is a palette
/// name the app maps to a `Color`.
public struct KindStyle: Equatable, Sendable {
  public let icon: String
  public let colorTag: String
  public init(icon: String, colorTag: String) { self.icon = icon; self.colorTag = colorTag }
}

public enum NodeKindStyle {
  public static func style(for kind: String) -> KindStyle {
    switch kind {
    case NodeKind.domain:     return KindStyle(icon: "sf:folder", colorTag: "gray")
    case NodeKind.project:    return KindStyle(icon: "sf:shippingbox", colorTag: "blue")
    case NodeKind.strand:     return KindStyle(icon: "sf:arrow.triangle.branch", colorTag: "teal")
    case NodeKind.concept:    return KindStyle(icon: "sf:lightbulb", colorTag: "yellow")
    case NodeKind.initiative: return KindStyle(icon: "sf:flag", colorTag: "orange")
    case NodeKind.task:       return KindStyle(icon: "sf:checklist", colorTag: "green")
    case NodeKind.topic:      return KindStyle(icon: "sf:tag", colorTag: "purple")
    default:                  return KindStyle(icon: "sf:shippingbox", colorTag: "blue")
    }
  }
}

/// Icon + palette color for an event's source (its `CaptureKind`). The localized *label* lives in
/// the app (localization is an app concern); Kit owns only the visual identity.
public struct SourceStyle: Equatable, Sendable {
  public let icon: String
  public let colorTag: String
  public init(icon: String, colorTag: String) { self.icon = icon; self.colorTag = colorTag }
}

public enum EventSourceStyle {
  public static func style(for eventKind: String) -> SourceStyle {
    switch eventKind {
    case CaptureKind.gitCommit:      return SourceStyle(icon: "sf:arrow.triangle.branch", colorTag: "indigo")
    case CaptureKind.gitCheckout:    return SourceStyle(icon: "sf:arrow.triangle.branch", colorTag: "indigo")
    case CaptureKind.ccSession:      return SourceStyle(icon: "sf:sparkles", colorTag: "orange")
    case CaptureKind.ccSessionStart: return SourceStyle(icon: "sf:sparkles", colorTag: "orange")
    default:                         return SourceStyle(icon: "sf:questionmark.circle", colorTag: "gray")
    }
  }
}

/// A node's *effective* appearance: its own icon/color if set, else the kind default.
public struct NodeAppearance: Equatable, Sendable {
  public let icon: AppearanceIcon
  public let colorTag: String
  public init(icon: AppearanceIcon, colorTag: String) { self.icon = icon; self.colorTag = colorTag }
}

public extension Node {
  var appearance: NodeAppearance {
    let kindStyle = NodeKindStyle.style(for: kind)
    let resolvedIcon = AppearanceIcon.parse(icon)
      ?? AppearanceIcon.parse(kindStyle.icon)
      ?? .sfSymbol("shippingbox")
    let resolvedColor = colorTag.isEmpty ? kindStyle.colorTag : colorTag
    return NodeAppearance(icon: resolvedIcon, colorTag: resolvedColor)
  }
}
