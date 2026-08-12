// Sources/PensieveApp/LooseEndRow.swift
import SwiftUI
import PensieveKit

/// One loose-end row: a tappable summary that, when expanded, shows its provenance in a soft rounded
/// box — a couple-line preview of the cited line, with a disclosure to expand to the full surrounding
/// transcript (cited message highlighted, machine-envelope messages dimmed). When the transcript is
/// gone it degrades honestly to the stored quote + a note. This replaces the old side-panel inspector:
/// one click, everything grounded in place. Shared by the detail recall + the middle worklist.
struct LooseEndRow: View {
  let view: LooseEndView
  /// Resolves the surrounding-transcript context off the main actor (file I/O). Pass `model.provenance`.
  let loadProvenance: (LooseEnd) async -> ProvenanceContext?
  /// Confirms a salience label for this loose end (👍 salient / 👎 noise / "" clears). Pass
  /// `model.setLooseEndLabel`.
  let onLabel: (UUID, String) -> Void
  /// When this equals the row's loose end, the row starts/auto-expands (a search hit landing here).
  var expandedLooseEndID: UUID?
  /// True in the middle column, where ~180pt is usable. Drops bubbles and tightens the type scale.
  var compact: Bool = false

  @State private var expanded = false            // the loose-end row itself
  @State private var provenanceExpanded = false  // the provenance box's own show-more/less
  @State private var context: ProvenanceContext?
  @State private var loading = false
  /// Segments parallel to `context.messages`, parsed once when the context loads.
  /// Deliberately NOT a shared cache: `ProvenanceMessage.index` is per-session, so an
  /// index-keyed cache could serve session A's segments for session B.
  @State private var parsed: [[TranscriptSegment]] = []

  /// Optimistic override of the confirmed label so a tap reflects immediately (the injected
  /// `LooseEndView` is an immutable snapshot). nil = show the stored value. The row is filtered out
  /// of the open list on the next reload when confirmed noise.
  @State private var localLabel: String?
  @State private var hovering = false

  /// The label to display: the optimistic local value if the user just tapped, else the stored one.
  private var currentLabel: String { localLabel ?? view.looseEnd.label }

  /// Both the thumb buttons and the context menu write through here.
  private func setLabel(_ value: String) {
    localLabel = value
    onLabel(view.looseEnd.id, value)
  }

  /// A thumb the user has actually set stays visible unconditionally — a confirmed label is recorded
  /// state, not an affordance, and hiding it would make the app appear to forget a decision. The
  /// machine's *suggestion* earns no such permanence.
  private var showsThumbs: Bool { hovering || !currentLabel.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Button {
          expanded.toggle()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.caption2).foregroundStyle(.secondary)
            Text(view.looseEnd.text).prose()
          }
        }
        .buttonStyle(.plain)
        Spacer()
        thumbs
      }

      if expanded {
        let roleText = view.looseEnd.role.isEmpty ? String(localized: "captured") : view.looseEnd.role
        VStack(alignment: .leading, spacing: 8) {
          provenanceBody
          // Was a hand-built `%lldd ago` whose catalog key said `%@d ago`, so it never matched and
          // rendered English inside a German window. Foundation formats the date instead — no
          // interpolated Int, no key, no way to mis-author it.
          (Text(roleText)
            + Text(verbatim: " · ")
            + Text(view.occurredAt, format: .dateTime.year().month().day())
            + Text(verbatim: " · ")
            + Text(view.occurredAt, format: .relative(presentation: .named)))
            .metaText()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.leading, 18)
        .padding(.top, 2)
      }
    }
    .padding(.vertical, 2)
    // Without this the row's hit region is only its rendered glyphs — the `Spacer()` between the
    // text and the thumbs is dead space, so moving the pointer horizontally toward a thumb left
    // the hover region and the thumb vanished before it could be clicked.
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    // Keyboard- and pointer-free access to the same two verbs the hover-revealed thumbs offer.
    .contextMenu {
      Button("Mark as a real loose end") { setLabel(LooseEndLabel.salient) }
      Button("Mark as not a loose end") { setLabel(LooseEndLabel.noise) }
      if !currentLabel.isEmpty {
        Divider()
        Button("Clear rating") { setLabel(LooseEndLabel.unlabeled) }
      }
    }
    // Load the surrounding transcript the first time the row is expanded (cached thereafter).
    .task(id: expanded) {
      guard expanded, context == nil else { return }
      loading = true
      let loaded = await loadProvenance(view.looseEnd)
      context = loaded
      parsed = (loaded?.messages ?? []).map { TranscriptMarkup.parse($0.text) }
      loading = false
    }
    .onAppear { if expandedLooseEndID == view.looseEnd.id { expanded = true } }
    .onChange(of: expandedLooseEndID) { _, newValue in
      if newValue == view.looseEnd.id { expanded = true }
    }
  }

  @ViewBuilder private var provenanceBody: some View {
    if let ctx = context, ctx.transcriptAvailable {
      let cited = ctx.messages.first(where: \.isCited) ?? ctx.messages.first
      if ctx.messages.count > 1 {
        if provenanceExpanded {
          ForEach(Array(ctx.messages.enumerated()), id: \.element.index) { idx, msg in
            messageRow(msg, showsRole: idx == 0 || speakerClass(for: ctx.messages[idx - 1]) != speakerClass(for: msg))
          }
        } else if let cited {
          previewRow(cited)
        }
        disclosureButton
      } else {
        ForEach(ctx.messages, id: \.index) { messageRow($0, showsRole: true) }
      }
    } else if loading {
      ProgressView().controlSize(.small)
    } else {
      // Honest fallback: the stored verbatim quote + why there's no surrounding context.
      Text(view.looseEnd.quote)
        .prose().italic().padding(.leading, 10)
        .overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 3) }
      if context != nil {
        Text("Surrounding context unavailable (transcript changed or removed).").metaText()
      }
    }
  }

  @ViewBuilder private var thumbs: some View {
    HStack(spacing: 10) {
      thumb(systemFilled: "hand.thumbsup.fill", systemOutline: "hand.thumbsup",
            value: LooseEndLabel.salient, help: String(localized: "Mark as a real loose end"))
      thumb(systemFilled: "hand.thumbsdown.fill", systemOutline: "hand.thumbsdown",
            value: LooseEndLabel.noise, help: String(localized: "Mark as not a loose end"))
    }
    .font(.caption)
    // Opacity, not `if` — the row must not reflow when the pointer arrives.
    .opacity(showsThumbs ? 1 : 0)
    .allowsHitTesting(showsThumbs)
    .accessibilityHidden(!showsThumbs)
  }

  /// One thumb. Filled when the confirmed label matches; a faint pre-highlight when only SUGGESTED
  /// (guess awaiting confirm). Tapping toggles: tap the active label again to clear it.
  @ViewBuilder private func thumb(systemFilled: String, systemOutline: String,
                                  value: String, help: String) -> some View {
    let confirmed = currentLabel == value
    let suggested = currentLabel.isEmpty && view.looseEnd.labelSuggestion == value
    Button {
      setLabel(confirmed ? LooseEndLabel.unlabeled : value)
    } label: {
      Image(systemName: confirmed ? systemFilled : systemOutline)
        .foregroundStyle(confirmed ? Color.accentColor : (suggested ? Color.accentColor.opacity(0.55) : Color.secondary))
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
  }

  private var disclosureButton: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.15)) { provenanceExpanded.toggle() }
    } label: {
      Label(provenanceExpanded ? "Show less" : "Show more",
            systemImage: provenanceExpanded ? "chevron.up" : "chevron.down")
        .font(.caption).foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .padding(.top, 2)
  }

  /// Collapsed preview: the cited message's first renderable segment, capped to a few lines.
  @ViewBuilder private func previewRow(_ msg: ProvenanceMessage) -> some View {
    TranscriptMessageView(message: msg, segments: previewSegments(for: msg), compact: true)
      .lineLimit(3)
  }

  @ViewBuilder private func messageRow(_ msg: ProvenanceMessage, showsRole: Bool) -> some View {
    TranscriptMessageView(message: msg, segments: segments(for: msg),
                          compact: compact, showsRoleLabel: showsRole)
  }

  /// Segments for a message, by position in the parallel `parsed` array. Falls back to a single
  /// raw markdown segment if the arrays ever disagree — never renders nothing.
  private func segments(for msg: ProvenanceMessage) -> [TranscriptSegment] {
    guard let ctx = context,
          let pos = ctx.messages.firstIndex(where: { $0.index == msg.index }),
          pos < parsed.count
    else { return [.markdown(msg.text)] }
    return parsed[pos]
  }

  /// The caption shown for a message is its `SpeakerClass`, not its raw `role` — an `assistant`
  /// message that classifies `.system` (e.g. all-`<tool_uses>`) must not be conflated with a
  /// following prose `assistant` message that classifies `.claude`, or the caption is wrongly
  /// suppressed and the reader misattributes the speaker.
  private func speakerClass(for msg: ProvenanceMessage) -> SpeakerClass {
    .of(msg, segments: segments(for: msg))
  }

  /// The preview shows only the first meaningful segment — a harness envelope alone would tell the
  /// reader nothing about why this loose end exists.
  private func previewSegments(for msg: ProvenanceMessage) -> [TranscriptSegment] {
    let all = segments(for: msg)
    let firstProse = all.first { segment in
      switch segment {
      case .markdown(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      case .callout: return true
      case .harness: return false
      }
    }
    return [firstProse ?? all.first ?? .markdown(msg.text)]
  }
}
