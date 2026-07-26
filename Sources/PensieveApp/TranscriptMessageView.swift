// Sources/PensieveApp/TranscriptMessageView.swift
import SwiftUI
import PensieveKit

extension SpeakerClass {
  /// Chrome → localized. Content is never localized.
  var label: String {
    switch self {
    case .you: return String(localized: "You")
    case .claude: return String(localized: "Claude")
    case .system: return String(localized: "System")
    }
  }
}

/// One message: a role caption plus its segments, in a container chosen by speaker class.
struct TranscriptMessageView: View {
  let message: ProvenanceMessage
  let segments: [TranscriptSegment]
  /// True in the middle column (~180pt usable): full-width stack, no bubbles, no alternation.
  let compact: Bool
  /// Suppressed when the previous message has the same speaker (Decision 6).
  var showsRoleLabel: Bool = true

  private var speaker: SpeakerClass { .of(message, segments: segments) }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if showsRoleLabel {
        Text(speaker.label)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
          TranscriptSegmentView(segment: segment)
        }
      }
      .padding(bubbled ? 10 : 0)
      .padding(.leading, bubbled ? 0 : 10)
      .background {
        if bubbled {
          RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10))
        }
      }
      .overlay(alignment: .leading) {
        // The cited-provenance marker. `ProvenanceQueries` hard-guards `citedMessage.isUserPrompt`,
        // so the cited message is ALWAYS the `.you` class — this bar must survive every layout
        // choice below, which is why both fallbacks in the spec preserve it.
        if message.isCited { Rectangle().fill(.orange).frame(width: 3) }
      }
      .overlay {
        if message.isCited, bubbled {
          RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.5))
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .opacity(speaker == .system ? 0.75 : 1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(speaker.label)
  }

  /// **Pre-committed fallback taken (spec §Risks).** Trailing-aligned bubbles inside a `List` row
  /// are unverified, and the cited message is always the class that would carry them — so the
  /// fallback layout ships by default: full-width for all three classes, class conveyed by role
  /// caption + background tint. Bubbles remain available for the wide detail pane only.
  private var bubbled: Bool { !compact && speaker != .system }
}
