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
        HStack(alignment: .top, spacing: 12) {
          NodeBadge(node: node, size: 44)
          VStack(alignment: .leading, spacing: 4) {
            Text(node.name).font(.largeTitle).bold()
            HStack(spacing: 6) {
              Text(AppearanceStyle.kindLabel(node.kind)).foregroundStyle(.secondary)
              Text("·").foregroundStyle(.secondary)
              Circle().fill(AppearanceStyle.stateColor(node.state)).frame(width: 8, height: 8)
              Text(AppearanceStyle.stateLabel(node.state)).foregroundStyle(.secondary)
            }
            if !node.description.isEmpty {
              Text(node.description).prose().padding(.top, 2)
            }
          }
        }

        // LAST WORK DONE (LLM narration; prose-first — a ready recap always wins over an in-flight
        // flag — and the section is omitted entirely when there's no genuine narration).
        if let lastWorkDone, loadedNodeID == node.id {
          section("Last Work Done") {
            Text(lastWorkDone).prose()
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

        // RECENT ACTIVITY (GitHub-style rail timeline)
        section("Recent Activity") {
          if recentEvents.isEmpty {
            Text("No captured activity.").foregroundStyle(.secondary)
          } else {
            ActivityTimeline(events: recentEvents)
          }
        }
      }
      .padding(24)
      .frame(maxWidth: Prose.measure, alignment: .leading)
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
          Text(view.looseEnd.text).prose()
          Spacer()
        }
      }
      .buttonStyle(.plain)

      if isOpen {
        // The provenance: verbatim quote + where it came from. North-star made visible.
        VStack(alignment: .leading, spacing: 4) {
          Text(view.looseEnd.quote)
            .prose()
            .italic()
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
              Rectangle().fill(.orange).frame(width: 3)
            }
          Text("\(view.looseEnd.role.isEmpty ? String(localized: "captured") : view.looseEnd.role) · \(view.occurredAt, format: .dateTime.year().month().day()) · \(view.ageDays)d ago")
            .metaText()
        }
        .padding(.leading, 18)
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder private func section(_ title: LocalizedStringResource, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).sectionHeader()
      content()
    }
  }
}

private struct DetailLoadKey: Hashable { let nodeID: UUID; let token: Int }

/// A GitHub-style vertical-rail timeline: events grouped by day, a colored dot per event on a rail,
/// the source icon+color, the localized source label, and the summary. No avatars (single-user).
private struct ActivityTimeline: View {
  let events: [Event]

  var body: some View {
    let groups = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.occurredAt) }
    let days = groups.keys.sorted(by: >)
    VStack(alignment: .leading, spacing: 16) {
      ForEach(days, id: \.self) { day in
        let items = (groups[day] ?? []).sorted { $0.occurredAt > $1.occurredAt }
        VStack(alignment: .leading, spacing: 12) {
          Text(day, format: .dateTime.weekday(.wide).month().day())
            .font(.subheadline).fontWeight(.semibold).foregroundStyle(.primary)
          ForEach(Array(items.enumerated()), id: \.element.id) { idx, event in
            TimelineRow(event: event, isLast: idx == items.count - 1)
          }
        }
      }
    }
  }
}

private struct TimelineRow: View {
  let event: Event
  let isLast: Bool

  var body: some View {
    let style = EventSourceStyle.style(for: event.kind)
    let color = AppearanceStyle.color(style.colorTag)
    HStack(alignment: .top, spacing: 10) {
      VStack(spacing: 0) {
        Circle().fill(color).frame(width: 8, height: 8).padding(.top, 2)
        if !isLast { Rectangle().fill(.quaternary).frame(width: 1.5).frame(maxHeight: .infinity) }
      }
      .frame(width: 8)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          sourceIcon(style).font(.caption).foregroundStyle(color)
          Text(AppearanceStyle.sourceLabel(event.kind)).metaText()
          Text(event.occurredAt, format: .dateTime.hour().minute())
            .metaText().monospacedDigit()
        }
        Text(event.summary).prose()
      }
      Spacer()
    }
  }

  @ViewBuilder private func sourceIcon(_ s: SourceStyle) -> some View {
    switch AppearanceIcon.parse(s.icon) {
    case .sfSymbol(let n): Image(systemName: n)
    case .emoji(let e):    Text(e)
    case nil:              Image(systemName: "circle.fill")
    }
  }
}
