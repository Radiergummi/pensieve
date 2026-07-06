// Sources/PensieveApp/InspectorView.swift
import SwiftUI
import PensieveKit

/// The ⌘⌥I deep-dive: the surrounding transcript context for the inspected loose end. Cited message
/// highlighted; non-user (machine-envelope) messages dimmed. Honest "gone" note when the transcript
/// is no longer on disk — never a fabrication.
struct InspectorView: View {
  @ObservedObject var model: AppModel
  /// The loaded loose ends for the current node (for the stored-quote fallback + row lookup).
  let looseEnds: [LooseEndView]
  @State private var context: ProvenanceContext?
  @State private var loading = false

  private var selected: LooseEnd? {
    guard let id = model.inspectedLooseEndID else { return nil }
    return looseEnds.first { $0.looseEnd.id == id }?.looseEnd
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let le = selected {
          Text("PROVENANCE").font(.caption).bold().foregroundStyle(.secondary)
          Text(le.text).font(.headline)
          if let ctx = context, ctx.transcriptAvailable {
            ForEach(ctx.messages, id: \.index) { msg in
              messageRow(msg)
            }
          } else if loading {
            ProgressView().controlSize(.small)
          } else {
            // Honest fallback: the stored verbatim quote + why there's no context.
            Text(le.quote).italic().padding(.leading, 10)
              .overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 3) }
            Text("Source transcript no longer on disk.").font(.caption).foregroundStyle(.secondary)
          }
        } else {
          ContentUnavailableView("Select a loose end", systemImage: "quote.opening",
                                 description: Text("Pick a loose end to see its source."))
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task(id: model.inspectedLooseEndID) {
      context = nil
      guard let le = selected else { return }
      loading = true
      context = await model.provenance(for: le)
      loading = false
    }
  }

  @ViewBuilder private func messageRow(_ msg: ProvenanceMessage) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(msg.role).font(.caption2).foregroundStyle(.tertiary)
      Text(msg.text)
        .font(.callout)
        .padding(.leading, msg.isCited ? 10 : 0)
        .overlay(alignment: .leading) {
          if msg.isCited { Rectangle().fill(.orange).frame(width: 3) }
        }
    }
    .opacity(msg.isUserPrompt ? 1 : 0.55)   // dim machine-envelope context
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
