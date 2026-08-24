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

  /// The rail's width. Fixed rather than intrinsic so every message's content column starts at the
  /// same x — an intrinsic width would make "You" and "Claude" indent their bodies differently, which
  /// is the misalignment the rail exists to remove.
  private static let railWidth: CGFloat = 58

  var body: some View {
    Group {
      if compact { stacked } else { railed }
    }
    .opacity(speaker == .system ? 0.75 : 1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(speaker.label)
  }

  /// Wide layout: a fixed leading gutter carries the speaker, so the caption reads as attribution for
  /// the message instead of a caption on the box around it — which is what it was until C1, sitting
  /// outside the message bubble but inside the provenance card.
  private var railed: some View {
    HStack(alignment: .top, spacing: 12) {
      Group {
        if showsRoleLabel {
          Text(speaker.label)                     // chrome → localized, and already resolved
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
        }
      }
      // An empty Group still reserves the gutter, which is what keeps a suppressed caption from
      // shifting its content column. Deliberately NOT `Text("")`: an empty literal at a Text site is
      // a localizing site to CatalogCoverageTests and would demand a catalog key for "".
      .frame(width: Self.railWidth, alignment: .trailing)
      // Optical alignment with the body's first line. A bubbled message's `content` carries its own
      // 10pt top padding (below), so the caption needs 3 + 10 = 13pt to still land level with it.
      .padding(.top, bubbled ? 13 : 3)
      content
    }
  }

  /// Compact layout: today's stacked caption. The rail costs 58pt of a ~180pt usable column, so the
  /// middle column cannot have it.
  private var stacked: some View {
    VStack(alignment: .leading, spacing: 4) {
      if showsRoleLabel {
        Text(speaker.label)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      content
    }
  }

  /// The message's segments, with the bubble, the cited marker and the padding that pairs with them.
  /// Shared by both layouts so the marker cannot diverge between them.
  private var content: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(segments.enumerated()), id: \.offset) { ordinal, segment in
        TranscriptSegmentView(segment: segment, highlight: highlights[ordinal])
          .modifier(OptionalFindSite(anchor: anchorForSegment?(ordinal), find: find))
      }
    }
    .padding(bubbled ? 10 : 0)
    // The unbubbled leading inset matches the bubble's own, so a bubbled and an unbubbled message
    // start their text at the same x — and it leaves the cited bar somewhere to sit.
    .padding(.leading, bubbled ? 0 : 10)
    .background {
      if bubbled {
        RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10))
      }
    }
    .overlay {
      // The cited-provenance marker. `ProvenanceQueries.swift:46` passes `requireUserPrompt: true`
      // into `TranscriptWindow.slice`, so the cited message is ALWAYS the `.you` class — which since
      // C1 is also the only bubbled class, so the bar and the border always land together in the wide
      // pane. The bar is clipped in the bubble's coordinate space, so its ends follow the corner
      // curve instead of poking out square-cornered past the rounded border. It rides `content`, never
      // the rail: a bar through the speaker caption would read as marking the speaker, not the quote.
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

  /// One meaning, since C1: **a person typed this**. It was `speaker != .system` — the readability
  /// spec's pre-committed fallback, taken because trailing-aligned bubbles inside a `List` row were
  /// unverified — which bubbled You and Claude alike and so distinguished nothing.
  private var bubbled: Bool { !compact && speaker == .you }
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
