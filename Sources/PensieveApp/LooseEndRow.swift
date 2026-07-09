// Sources/PensieveApp/LooseEndRow.swift
import SwiftUI
import PensieveKit
import MarkdownUI

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

  @State private var expanded = false            // the loose-end row itself
  @State private var provenanceExpanded = false  // the provenance box's own show-more/less
  @State private var context: ProvenanceContext?
  @State private var loading = false

  /// Optimistic override of the confirmed label so a tap reflects immediately (the injected
  /// `LooseEndView` is an immutable snapshot). nil = show the stored value. The row is filtered out
  /// of the open list on the next reload when confirmed noise.
  @State private var localLabel: String?

  /// The label to display: the optimistic local value if the user just tapped, else the stored one.
  private var currentLabel: String { localLabel ?? view.looseEnd.label }

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
        VStack(alignment: .leading, spacing: 8) {
          provenanceBody
          Text("\(view.looseEnd.role.isEmpty ? String(localized: "captured") : view.looseEnd.role) · \(view.occurredAt, format: .dateTime.year().month().day()) · \(view.ageDays)d ago")
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
    // Load the surrounding transcript the first time the row is expanded (cached thereafter).
    .task(id: expanded) {
      guard expanded, context == nil else { return }
      loading = true
      context = await loadProvenance(view.looseEnd)
      loading = false
    }
  }

  @ViewBuilder private var provenanceBody: some View {
    if let ctx = context, ctx.transcriptAvailable {
      let cited = ctx.messages.first(where: \.isCited) ?? ctx.messages.first
      if ctx.messages.count > 1 {
        if provenanceExpanded {
          ForEach(ctx.messages, id: \.index) { messageRow($0) }
        } else if let cited {
          previewRow(cited)
        }
        disclosureButton
      } else {
        ForEach(ctx.messages, id: \.index) { messageRow($0) }
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
  }

  /// One thumb. Filled when the confirmed label matches; a faint pre-highlight when only SUGGESTED
  /// (guess awaiting confirm). Tapping toggles: tap the active label again to clear it.
  @ViewBuilder private func thumb(systemFilled: String, systemOutline: String,
                                  value: String, help: String) -> some View {
    let confirmed = currentLabel == value
    let suggested = currentLabel.isEmpty && view.looseEnd.labelSuggestion == value
    Button {
      let next = confirmed ? LooseEndLabel.unlabeled : value
      localLabel = next
      onLabel(view.looseEnd.id, next)
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

  /// Collapsed preview: the cited line as plain text, capped to a couple of lines.
  @ViewBuilder private func previewRow(_ msg: ProvenanceMessage) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(msg.role).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
      Text(msg.text).prose().lineLimit(3)
        .padding(.leading, 10)
        .overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 3) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private func messageRow(_ msg: ProvenanceMessage) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(msg.role).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
      Markdown(msg.text)
        .markdownTextStyle { FontSize(14) }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, msg.isCited ? 10 : 0)
        .overlay(alignment: .leading) {
          if msg.isCited { Rectangle().fill(.orange).frame(width: 3) }
        }
    }
    .opacity(msg.isUserPrompt ? 1 : 0.7)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
