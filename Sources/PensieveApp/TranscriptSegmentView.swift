// Sources/PensieveApp/TranscriptSegmentView.swift
import SwiftUI
import PensieveKit
import MarkdownUI

/// A matched segment's highlight runs, plus which of them is the current match. Computed where the
/// find state and the segment array meet (`LooseEndRow.highlights`).
struct SegmentHighlight {
  let runs: [FindRun]
  let currentOffset: Int?
}

/// Renders one parsed transcript segment. All parsing lives in PensieveKit's `TranscriptMarkup`;
/// this file only decides what each segment looks like.
struct TranscriptSegmentView: View {
  let segment: TranscriptSegment
  /// Non-nil only while a find is open AND this segment matches. Carried but not yet drawn: painting
  /// the match means rendering the segment as plain highlighted text instead of Markdown (MarkdownUI
  /// 2.4.1 exposes no way to style a substring inside a rendered block — its AST types are internal),
  /// and that trade-off — visible raw syntax until the bar closes — is its own change.
  var highlight: SegmentHighlight?

  var body: some View {
    switch segment {
    case .markdown(let text):
      Markdown(text).transcriptProse()
    case .callout(let callout):
      CalloutView(callout: callout)
    case .harness(let block):
      HarnessCardView(block: block)
    }
  }
}

/// A severity-tinted emphasis block. MarkdownUI 2.4.1 has no native GitHub-alert support
/// (verified against the vendored checkout), so this is hand-drawn.
private struct CalloutView: View {
  let callout: TranscriptCallout

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: callout.severity.icon)
        Text(callout.severity.label)            // chrome → localized
          .fontWeight(.semibold)
        Text(callout.tagName)                   // CONTENT → verbatim, never localized
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      .font(.system(size: 12))
      .foregroundStyle(callout.severity.tint)

      Markdown(callout.body).transcriptProse()
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(callout.severity.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8).strokeBorder(callout.severity.tint.opacity(0.35)))
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// A machine envelope, rendered as a quiet card so it reads as "the harness", not "a person".
private struct HarnessCardView: View {
  let block: HarnessBlock

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(block.kind.label)                    // chrome → localized
        .font(.system(size: 11, weight: .semibold))
        .textCase(.uppercase)
        .tracking(0.5)
        .foregroundStyle(.secondary)
      if let body = block.kind.displayBody, !body.isEmpty {
        Text(body)                              // CONTENT → verbatim
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(12)
          .textSelection(.enabled)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    .fixedSize(horizontal: false, vertical: true)
  }
}

extension CalloutSeverity {
  var label: String {
    switch self {
    case .caution: return String(localized: "Caution")
    case .important: return String(localized: "Important")
    case .neutral: return String(localized: "Note")
    }
  }
  var tint: Color {
    switch self {
    case .caution: return .orange
    case .important: return .accentColor
    case .neutral: return .secondary
    }
  }
  var icon: String {
    switch self {
    case .caution: return "exclamationmark.triangle.fill"
    case .important: return "info.circle.fill"
    case .neutral: return "text.bubble"
    }
  }
}

extension HarnessKind {
  /// Chrome — localized. Never derived from a tag name, which is content.
  var label: String {
    switch self {
    case .command: return String(localized: "Command")
    case .taskNotification: return String(localized: "Task Update")
    case .systemReminder: return String(localized: "System Note")
    case .commandCaveat: return String(localized: "Note")
    case .commandOutput: return String(localized: "Output")
    case .bashIO: return String(localized: "Shell")
    case .toolUses: return String(localized: "Tool Use")
    case .toolUseError: return String(localized: "Tool Error")
    case .interrupted: return String(localized: "Interrupted")
    case .skillPreamble: return String(localized: "Skill")
    case .unknown: return String(localized: "Harness")
    }
  }
}

extension View {
  /// The transcript type scale: h1 22 · h2 18 · h3 16 · h4-h6 15/14/14 semibold · body 14/ls 4.
  /// MarkdownUI's defaults put h1 near 28pt against 14pt body, which reads as shouting in a
  /// chat transcript. Each heading override keeps `Theme.basic`'s margin (`BlockSequence` derives
  /// all inter-block spacing from it — dropping it collapses the space after a heading to zero).
  func transcriptProse() -> some View {
    self
      .markdownTextStyle { FontSize(14) }
      .lineSpacing(4)
      .markdownBlockStyle(\.heading1) {
        $0.label.markdownMargin(top: .rem(1), bottom: .rem(0.5))
          .markdownTextStyle { FontSize(22); FontWeight(.semibold) }
      }
      .markdownBlockStyle(\.heading2) {
        $0.label.markdownMargin(top: .rem(1), bottom: .rem(0.5))
          .markdownTextStyle { FontSize(18); FontWeight(.semibold) }
      }
      .markdownBlockStyle(\.heading3) {
        $0.label.markdownMargin(top: .rem(1), bottom: .rem(0.5))
          .markdownTextStyle { FontSize(16); FontWeight(.semibold) }
      }
      .markdownBlockStyle(\.heading4) {
        $0.label.markdownMargin(top: .rem(1), bottom: .rem(0.5))
          .markdownTextStyle { FontSize(15); FontWeight(.semibold) }
      }
      .markdownBlockStyle(\.heading5) {
        $0.label.markdownMargin(top: .rem(1), bottom: .rem(0.5))
          .markdownTextStyle { FontSize(14); FontWeight(.semibold) }
      }
      .markdownBlockStyle(\.heading6) {
        $0.label.markdownMargin(top: .rem(1), bottom: .rem(0.5))
          .markdownTextStyle { FontSize(14); FontWeight(.semibold) }
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
