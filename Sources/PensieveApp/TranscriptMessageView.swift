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
  /// Per-segment find highlight, keyed by segment ordinal. Empty when find is closed, when this
  /// surface is not find-scoped, or when nothing in this message matches.
  var highlights: [Int: SegmentHighlight] = [:]
  /// Builds the find anchor for a segment ordinal. nil on the two surfaces that cannot use one: the
  /// collapsed preview (`LooseEndRow.previewRow`), which renders a single segment at ordinal 0 whatever
  /// its true position, so an anchor there would name a site the document does not describe; and the
  /// surfaces with no find bar at all (the middle column, Review Suggestions), which pass `find` nil.
  var anchorForSegment: ((Int) -> FindAnchor)?
  var find: NodeFindState?

  private var speaker: SpeakerClass { .of(message, segments: segments) }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if showsRoleLabel {
        Text(speaker.label)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(segments.enumerated()), id: \.offset) { ordinal, segment in
          TranscriptSegmentView(segment: segment, highlight: highlights[ordinal])
            .modifier(OptionalFindSite(anchor: anchorForSegment?(ordinal), find: find))
        }
      }
      .padding(bubbled ? 10 : 0)
      .padding(.leading, bubbled ? 0 : 10)
      .background {
        if bubbled {
          RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10))
        }
      }
      .overlay {
        // The cited-provenance marker. `ProvenanceQueries` hard-guards `citedMessage.isUserPrompt`,
        // so the cited message is ALWAYS the `.you` class — this bar must survive every layout
        // choice below, which is why both fallbacks in the spec preserve it. The bar is clipped in
        // the bubble's coordinate space, so its ends follow the corner curve instead of poking out
        // square-cornered past the rounded border.
        if message.isCited {
          ZStack {
            if bubbled { RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.5)) }
            Rectangle().fill(.orange).frame(width: 3)
              .frame(maxWidth: .infinity, alignment: .leading)
              .clipShape(RoundedRectangle(cornerRadius: bubbled ? 12 : 0))
          }
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

/// Applies `.findSite` only to a segment that participates in find, so the surfaces that don't (the
/// collapsed preview, the middle column, Review Suggestions) keep their current view identity — a
/// `.id()` they never had would change it.
private struct OptionalFindSite: ViewModifier {
  let anchor: FindAnchor?
  let find: NodeFindState?

  @ViewBuilder func body(content: Content) -> some View {
    if let anchor { content.findSite(anchor, find) } else { content }
  }
}
