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
  /// Non-nil only while a find is open AND this segment matches. When set, the segment's BODY renders
  /// as plain highlighted text instead of Markdown: MarkdownUI 2.4.1 exposes no way to style a
  /// substring inside a rendered block (its AST types are internal), so this is the only way to
  /// highlight the phrase in place. The cost is visible raw syntax until the find bar closes.
  ///
  /// Only the body is flattened — a callout keeps its severity chrome and tag name, a harness block
  /// keeps its kind label and card. Those are what tell the reader WHAT the block is; swapping the
  /// whole view for bare text would turn a matched `<system-reminder>` into anonymous prose.
  var highlight: SegmentHighlight?

  var body: some View {
    switch segment {
    case .markdown(let text):
      if let highlight {
        HighlightedText(runs: highlight.runs, currentOffset: highlight.currentOffset)
          .transcriptPlainTextProse()
      } else {
        Markdown(text).transcriptProse()
      }
    case .callout(let callout):
      CalloutView(callout: callout, highlight: highlight)
    case .harness(let block):
      HarnessCardView(block: block, highlight: highlight)
    }
  }
}

/// A severity-tinted emphasis block. MarkdownUI 2.4.1 has no native GitHub-alert support
/// (verified against the vendored checkout), so this is hand-drawn.
private struct CalloutView: View {
  let callout: TranscriptCallout
  var highlight: SegmentHighlight?

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

      if let highlight {
        HighlightedText(runs: highlight.runs, currentOffset: highlight.currentOffset)
          .transcriptPlainTextProse()
      } else {
        Markdown(callout.body).transcriptProse()
      }
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
  var highlight: SegmentHighlight?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(block.kind.label)                    // chrome → localized
        .font(.system(size: 11, weight: .semibold))
        .textCase(.uppercase)
        .tracking(0.5)
        .foregroundStyle(.secondary)
      if let highlight {
        // No `lineLimit` while highlighted, deliberately: the body is indexed in FULL, so a phrase
        // past line 12 would otherwise be a counted match clipped out of view — a match the bar
        // promises and the pane never shows. The cap comes back the moment the find bar closes.
        HighlightedText(runs: highlight.runs, currentOffset: highlight.currentOffset)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      } else if let body = block.kind.displayBody, !body.isEmpty {
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
  /// The body-text half of `transcriptProse()`'s type scale (font 14 / line-spacing 4), for content
  /// that isn't a MarkdownUI `Markdown` view. `transcriptProse()`'s font/heading sizing goes through
  /// `.markdownTextStyle`/`.markdownBlockStyle`, which only set the `Theme` environment key that
  /// `Markdown` itself reads — a plain `Text` (e.g. a flattened, highlighted find match) never
  /// consults it, so it would silently render at the default system body size instead of matching
  /// its Markdown siblings. This applies the same two values via native SwiftUI modifiers instead.
  func transcriptPlainTextProse() -> some View {
    self
      .font(.system(size: 14))
      .lineSpacing(4)
  }

  /// The transcript type scale: h1 15 · h2-h6 14 semibold · body 14 / line-spacing 4. Two heading
  /// sizes, not six, and deliberately close to body size: a heading inside a QUOTED transcript is
  /// emphasis within the quote, not document structure. At MarkdownUI's defaults (h1 near 28 against
  /// 14pt body) it outranked the detail pane's own 13pt section headers, so captured content was the
  /// second-largest text on screen after the node name.
  /// Each heading override keeps `Theme.basic`'s margin (`BlockSequence` derives
  /// all inter-block spacing from it — dropping it collapses the space after a heading to zero).
  func transcriptProse() -> some View {
    self
      .markdownTextStyle { FontSize(14) }
      .lineSpacing(4)
      .markdownBlockStyle(\.heading1) {
        $0.label.markdownMargin(top: .rem(1), bottom: .rem(0.5))
          .markdownTextStyle { FontSize(15); FontWeight(.semibold) }
      }
      .markdownBlockStyle(\.heading2) {
        $0.label.markdownMargin(top: .rem(1), bottom: .rem(0.5))
          .markdownTextStyle { FontSize(14); FontWeight(.semibold) }
      }
      .markdownBlockStyle(\.heading3) {
        $0.label.markdownMargin(top: .rem(1), bottom: .rem(0.5))
          .markdownTextStyle { FontSize(14); FontWeight(.semibold) }
      }
      .markdownBlockStyle(\.heading4) {
        $0.label.markdownMargin(top: .rem(1), bottom: .rem(0.5))
          .markdownTextStyle { FontSize(14); FontWeight(.semibold) }
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
