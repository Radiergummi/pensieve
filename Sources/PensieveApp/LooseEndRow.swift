// Sources/PensieveApp/LooseEndRow.swift
import SwiftUI
import PensieveKit

/// One loose-end row: a tappable summary that discloses its verbatim quote + provenance meta inline,
/// and reports selection so the caller can point the ⌘⌥I inspector at it. Shared by the detail recall's
/// Loose Ends section and the middle worklist so both look and behave identically. Each row owns its own
/// expand state (rows are independent; no external set needed).
struct LooseEndRow: View {
  let view: LooseEndView
  /// Called on tap so the owner can set the inspected loose end (or no-op in a recall window).
  let onSelect: () -> Void
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        expanded.toggle()
        onSelect()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.caption2).foregroundStyle(.secondary)
          Text(view.looseEnd.text).prose()
          Spacer()
        }
      }
      .buttonStyle(.plain)

      if expanded {
        // The provenance: verbatim quote + where it came from. North-star made visible.
        VStack(alignment: .leading, spacing: 4) {
          Text(view.looseEnd.quote)
            .prose()
            .italic()
            .padding(.leading, 10)
            .overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 3) }
          Text("\(view.looseEnd.role.isEmpty ? String(localized: "captured") : view.looseEnd.role) · \(view.occurredAt, format: .dateTime.year().month().day()) · \(view.ageDays)d ago")
            .metaText()
        }
        .padding(.leading, 18)
      }
    }
    .padding(.vertical, 2)
  }
}
