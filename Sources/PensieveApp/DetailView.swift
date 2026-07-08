// Sources/PensieveApp/DetailView.swift
import SwiftUI
import PensieveKit

struct DetailView: View {
  @ObservedObject var model: AppModel
  @AppStorage(AppDefaults.narrationEnabledKey) private var narrationEnabled = true
  let node: Node
  /// When false, the detail omits its Loose Ends section (the middle column is showing this same
  /// node's loose ends — the one-home rule). Recall windows / smart-list details pass true.
  var showsLooseEnds: Bool = true
  // Loaded once per node selection via `.task(id:)` below — NOT recomputed on every body eval
  // (calling `model.detail(for:)` in the body would hit the DB on every render).
  @State private var recentEvents: [Event] = []
  @State private var looseEnds: [LooseEndView] = []
  @State private var lastWorkDone: String?
  @State private var isNarrating = false
  @State private var loadedNodeID: UUID?   // which node the current prose belongs to
  @State private var shareMarkdown = ""   // rebuilt on load/refresh; fed to the toolbar ShareLink

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
        if narrationEnabled, let lastWorkDone, loadedNodeID == node.id {
          section("Last Work Done") {
            VStack(alignment: .leading, spacing: 4) {
              Text(lastWorkDone).prose()
              Label("Generated summary", systemImage: "sparkles")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        } else if narrationEnabled, isNarrating, loadedNodeID == node.id {
          section("Last Work Done") {
            ProgressView().controlSize(.small)
          }
        }

        // LOOSE ENDS (with inline verbatim provenance) — omitted when the middle already shows them.
        if showsLooseEnds {
          section("Loose Ends") {
            if looseEnds.isEmpty {
              Text("None open.").foregroundStyle(.secondary)
            } else {
              ForEach(looseEnds, id: \.looseEnd.id) { view in
                LooseEndRow(view: view, loadProvenance: model.provenance)
              }
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
      .frame(maxWidth: .infinity, alignment: .center)   // center the capped reading column in a wide pane
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        ShareLink(item: shareMarkdown, subject: Text(node.name))
      }
    }
    // Re-runs on node change AND on ⌘R (refreshToken). The body order is load-bearing (two
    // independent reviews): reset prose only on a NODE change (so a same-node ⌘R keeps the old
    // recap visible until the new one lands — no flash), reset `isNarrating` on EVERY entry (never
    // leak `true` across a handoff), and guard `Task.isCancelled` before writing (a superseded
    // task's await still resumes — don't let a late result render under the new node).
    .task(id: DetailLoadKey(nodeID: node.id, token: model.refreshToken)) {
      // Same node + token bumped == a ⌘R refresh; a different node == navigation.
      let isRefresh = (loadedNodeID == node.id)
      if !isRefresh { lastWorkDone = nil }
      loadedNodeID = node.id
      isNarrating = false
      let d = model.detail(for: node)
      recentEvents = d.status.recentEvents
      looseEnds = d.looseEnds
      shareMarkdown = RecallMarkdown.render(node: node,
                                            narration: model.cachedNarration(for: node, events: recentEvents),
                                            looseEnds: looseEnds, events: recentEvents, now: Date())
      guard narrationEnabled else { lastWorkDone = nil; isNarrating = false; return }
      if !isRefresh, let cached = model.cachedNarration(for: node, events: recentEvents) {
        lastWorkDone = cached; return
      }
      isNarrating = true
      let prose = await model.narration(for: node, events: recentEvents, force: isRefresh)
      guard !Task.isCancelled else { return }   // superseded: new task owns state; don't touch isNarrating
      lastWorkDone = prose
      shareMarkdown = RecallMarkdown.render(node: node, narration: prose,
                                            looseEnds: looseEnds, events: recentEvents, now: Date())
      isNarrating = false
    }
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
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
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
