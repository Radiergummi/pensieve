// Sources/PensieveApp/PaletteView.swift
import SwiftUI
import PensieveKit

/// ⌘K fuzzy-jump. Navigation only: pick a destination and it sets the sidebar/detail selection.
struct PaletteView: View {
  @ObservedObject var model: AppModel
  @Binding var isPresented: Bool
  @State private var query = ""
  @FocusState private var focused: Bool

  private struct Row: Identifiable {
    let id: String
    let label: String
    let systemImage: String
    let destination: PaletteDestination
  }

  private var rows: [Row] {
    var out: [Row] = []
    let q = query.trimmingCharacters(in: .whitespaces)
    // Destinations (Briefing + smart lists) — shown when they match the query (or query is empty).
    func matches(_ s: String) -> Bool { q.isEmpty || s.range(of: q, options: .caseInsensitive) != nil }
    if matches("Briefing") {
      out.append(Row(id: "briefing", label: "Briefing", systemImage: "sun.max", destination: .briefing))
    }
    for kind in SmartListKind.allCases where matches(kind.title) {
      out.append(Row(id: "sl-\(kind.rawValue)", label: kind.title, systemImage: kind.symbol,
                     destination: .smartList(kind)))
    }
    for node in model.matchingNodes(q).prefix(20) {
      out.append(Row(id: "n-\(node.id)", label: node.name, systemImage: "shippingbox",
                     destination: .node(node.id)))
    }
    return out
  }

  var body: some View {
    VStack(spacing: 0) {
      TextField("Jump to…", text: $query)
        .textFieldStyle(.plain)
        .font(.title3)
        .padding(12)
        .focused($focused)
        .onSubmit { select(rows.first) }        // Enter jumps to the top match
      Divider()
      List(rows) { row in
        Button { select(row) } label: {
          Label(row.label, systemImage: row.systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
      }
      .frame(height: 320)
    }
    .frame(width: 480)
    .onAppear { focused = true }
  }

  private func select(_ row: Row?) {
    guard let row else { return }
    row.destination.apply(to: model)
    isPresented = false
  }
}
