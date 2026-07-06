// Sources/PensieveApp/DetailView.swift
import SwiftUI
import PensieveKit

struct DetailView: View {
  @ObservedObject var model: AppModel
  let node: Node
  /// When false (recall window), tapping a loose end never writes the shared inspector selection.
  var allowsInspector: Bool = true
  @State private var expanded: Set<UUID> = []
  // Loaded once per node selection via `.task(id:)` below — NOT recomputed on every body eval
  // (calling `model.detail(for:)` in the body would hit the DB on every render).
  @State private var recentEvents: [Event] = []
  @State private var looseEnds: [LooseEndView] = []
  @State private var lastWorkDone: String?
  @State private var isNarrating = false
  @State private var loadedNodeID: UUID?   // which node the current prose belongs to

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

        // LAST WORK DONE (LLM narration; prose-first — a ready recap always wins over an in-flight
        // flag — and the section is omitted entirely when there's no genuine narration).
        if let lastWorkDone, loadedNodeID == node.id {
          section("Last Work Done") {
            Text(lastWorkDone).font(.body)
          }
        } else if isNarrating, loadedNodeID == node.id {
          section("Last Work Done") {
            ProgressView().controlSize(.small)
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
    // Re-runs on node change AND on ⌘R (refreshToken). The body order is load-bearing (two
    // independent reviews): reset prose only on a NODE change (so a same-node ⌘R keeps the old
    // recap visible until the new one lands — no flash), reset `isNarrating` on EVERY entry (never
    // leak `true` across a handoff), and guard `Task.isCancelled` before writing (a superseded
    // task's await still resumes — don't let a late result render under the new node).
    .task(id: DetailLoadKey(nodeID: node.id, token: model.refreshToken)) {
      if loadedNodeID != node.id { lastWorkDone = nil }
      loadedNodeID = node.id
      isNarrating = false
      let d = model.detail(for: node)
      recentEvents = d.status.recentEvents
      looseEnds = d.looseEnds
      if let cached = model.cachedNarration(for: node) { lastWorkDone = cached; return }
      isNarrating = true
      let prose = await model.narration(for: node, events: recentEvents)
      guard !Task.isCancelled else { return }   // superseded: new task owns state; don't touch isNarrating
      lastWorkDone = prose
      isNarrating = false
    }
  }

  @ViewBuilder private func looseEndRow(_ view: LooseEndView) -> some View {
    let id = view.looseEnd.id
    let isOpen = expanded.contains(id)
    VStack(alignment: .leading, spacing: 6) {
      Button {
        if isOpen { expanded.remove(id) } else { expanded.insert(id) }
        if allowsInspector { model.inspectedLooseEndID = id }
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

private struct DetailLoadKey: Hashable { let nodeID: UUID; let token: Int }
