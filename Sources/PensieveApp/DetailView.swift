// Sources/PensieveApp/DetailView.swift
import SwiftUI
import PensieveKit

struct DetailView: View {
  @ObservedObject var model: AppModel
  let node: Node
  @State private var expanded: Set<UUID> = []
  // Loaded once per node selection via `.task(id:)` below — NOT recomputed on every body eval
  // (calling `model.detail(for:)` in the body would hit the DB on every render).
  @State private var recentEvents: [Event] = []
  @State private var looseEnds: [LooseEndView] = []

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // WHAT IT IS
        VStack(alignment: .leading, spacing: 4) {
          Text(node.name).font(.largeTitle).bold()
          Text("\(node.kind) · \(node.state)").foregroundStyle(.secondary)
          if !node.description.isEmpty {
            Text(node.description).font(.body).padding(.top, 2)
          }
        }

        // LOOSE ENDS (with inline verbatim provenance)
        section("Loose Ends") {
          if looseEnds.isEmpty {
            Text("None open.").foregroundStyle(.secondary)
          } else {
            ForEach(looseEnds, id: \.looseEnd.id) { view in
              looseEndRow(view)
            }
          }
        }

        // RECENT ACTIVITY (deterministic; LLM narration is a later slice)
        section("Recent Activity") {
          if recentEvents.isEmpty {
            Text("No captured activity.").foregroundStyle(.secondary)
          } else {
            ForEach(recentEvents) { event in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.occurredAt, format: .dateTime.month().day())
                  .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                  .frame(width: 52, alignment: .leading)
                Text(event.summary).font(.callout)
                Spacer()
                Text(event.kind).font(.caption2).foregroundStyle(.tertiary)
              }
            }
          }
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    // Runs on first appearance and whenever the selected node changes — one DB read per
    // selection, not per render. `.task` on a View is MainActor-isolated, so the synchronous
    // `@MainActor` call to `model.detail(for:)` needs no `await`.
    .task(id: node.id) {
      let d = model.detail(for: node)
      recentEvents = d.status.recentEvents
      looseEnds = d.looseEnds
    }
  }

  @ViewBuilder private func looseEndRow(_ view: LooseEndView) -> some View {
    let id = view.looseEnd.id
    let isOpen = expanded.contains(id)
    VStack(alignment: .leading, spacing: 6) {
      Button {
        if isOpen { expanded.remove(id) } else { expanded.insert(id) }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isOpen ? "chevron.down" : "chevron.right")
            .font(.caption2).foregroundStyle(.secondary)
          Text(view.looseEnd.text)
          Spacer()
        }
      }
      .buttonStyle(.plain)

      if isOpen {
        // The provenance: verbatim quote + where it came from. North-star made visible.
        VStack(alignment: .leading, spacing: 4) {
          Text(view.looseEnd.quote)
            .italic()
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
              Rectangle().fill(.orange).frame(width: 3)
            }
          Text("\(view.looseEnd.role.isEmpty ? "captured" : view.looseEnd.role) · \(view.occurredAt, format: .dateTime.year().month().day()) · \(view.ageDays)d ago")
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 18)
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
      content()
    }
  }
}
