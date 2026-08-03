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
  static func kindLabel(_ kind: NodeKind) -> LocalizedStringResource {
    switch kind {
    case .domain:     return "Domain"
    case .project:    return "Project"
    case .strand:     return "Strand"
    case .concept:    return "Concept"
    case .initiative: return "Initiative"
    case .task:       return "Task"
    case .topic:      return "Topic"
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

  static func stateLabel(_ state: NodeState) -> LocalizedStringResource {
    switch state {
    case .muted:    return "Muted"
    case .archived: return "Archived"
    case .active:   return "Active"
    }
  }

  static func stateColor(_ state: NodeState) -> Color {
    switch state {
    case .muted:    return .orange
    case .archived: return .gray
    case .active:   return .green
    }
  }
}

/// A node's effective icon in a colored rounded-rect badge. Reused in the sidebar tree, the middle
/// list, and the detail header.
struct NodeBadge: View {
  let node: Node
  var size: CGFloat = 22

  var body: some View {
    let appearance = node.appearance
    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
      .fill(AppearanceStyle.color(appearance.colorTag))
      .frame(width: size, height: size)
      .overlay {
        Group {
          switch appearance.icon {
          case .sfSymbol(let name): Image(systemName: name).foregroundStyle(.white)
          case .emoji(let emoji):       Text(emoji)
          }
        }
        .font(.system(size: size * 0.55))
      }
  }
}
