// Sources/PensieveApp/AppearanceStyle.swift
import SwiftUI
import PensieveKit

/// App-side bridge from Kit's SwiftUI-free identity strings to SwiftUI values, plus the localized
/// chrome labels for kinds/sources/states. One place, reused by sidebar, list, header, timeline.
enum AppearanceStyle {
  /// The fixed Reminders-style palette. A `colorTag` (stored on Node or returned by the Kit style
  /// tables) maps to a Color here; an unknown tag falls back to the accent color.
  static let palette: [(tag: String, color: Color)] = [
    ("red", .red), ("orange", .orange), ("yellow", .yellow), ("green", .green),
    ("mint", .mint), ("teal", .teal), ("blue", .blue), ("indigo", .indigo),
    ("purple", .purple), ("pink", .pink), ("brown", .brown), ("gray", .gray),
  ]

  static func color(_ tag: String) -> Color {
    palette.first { $0.tag == tag }?.color ?? .accentColor
  }

  /// Localized kind label (chrome). English literals double as the String Catalog keys.
  static func kindLabel(_ kind: String) -> LocalizedStringResource {
    switch kind {
    case NodeKind.domain:     return "Domain"
    case NodeKind.project:    return "Project"
    case NodeKind.strand:     return "Strand"
    case NodeKind.concept:    return "Concept"
    case NodeKind.initiative: return "Initiative"
    case NodeKind.task:       return "Task"
    case NodeKind.topic:      return "Topic"
    default:                  return "Project"
    }
  }

  /// Localized source label (chrome) for an event's `CaptureKind`.
  static func sourceLabel(_ eventKind: String) -> LocalizedStringResource {
    switch eventKind {
    case CaptureKind.gitCommit:                        return "Git Commit"
    case CaptureKind.gitCheckout:                      return "Git Checkout"
    case CaptureKind.ccSession, CaptureKind.ccSessionStart: return "Claude Code Session"
    default:                                           return "Activity"
    }
  }

  static func stateLabel(_ state: String) -> LocalizedStringResource {
    switch state {
    case "muted":    return "Muted"
    case "archived": return "Archived"
    default:         return "Active"
    }
  }

  static func stateColor(_ state: String) -> Color {
    switch state {
    case "muted":    return .orange
    case "archived": return .gray
    default:         return .green
    }
  }
}

/// A node's effective icon in a colored rounded-rect badge. Reused in the sidebar tree, the middle
/// list, and the detail header.
struct NodeBadge: View {
  let node: Node
  var size: CGFloat = 22

  var body: some View {
    let a = node.appearance
    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
      .fill(AppearanceStyle.color(a.colorTag))
      .frame(width: size, height: size)
      .overlay {
        Group {
          switch a.icon {
          case .sfSymbol(let name): Image(systemName: name).foregroundStyle(.white)
          case .emoji(let e):       Text(e)
          }
        }
        .font(.system(size: size * 0.55))
      }
  }
}
