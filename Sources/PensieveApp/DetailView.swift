// Sources/PensieveApp/DetailView.swift
import SwiftUI
import PensieveKit

struct DetailView: View {
  var model: AppModel
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
  @State private var isDescribing = false
  @State private var describeNote: String?   // brief inline note when a refresh yields nothing
  @State private var describable = false
  @State private var loadedNodeID: UUID?   // which node the current prose belongs to
  @State private var shareMarkdown = ""   // rebuilt on load/refresh; fed to the toolbar ShareLink
  @State private var find = NodeFindState()

  var body: some View {
    VStack(spacing: 0) {
      if find.isPresented, find.nodeID == node.id { FindBar(find: find) }
      ScrollViewReader { proxy in
      ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // WHAT IT IS
        HStack(alignment: .top, spacing: 12) {
          NodeBadge(node: node, size: 44)
          VStack(alignment: .leading, spacing: 4) {
            findableText(node.name, anchor: .nodeName).font(.largeTitle).bold()
            HStack(spacing: 6) {
              Text(AppearanceStyle.kindLabel(node.kind)).foregroundStyle(.secondary)
              Text("·").foregroundStyle(.secondary)
              Circle().fill(AppearanceStyle.stateColor(node.state)).frame(width: 8, height: 8)
              Text(AppearanceStyle.stateLabel(node.state)).foregroundStyle(.secondary)
            }
            descriptionBlock
          }
        }

        // LAST WORK DONE (LLM narration; prose-first — a ready recap always wins over an in-flight
        // flag — and the section is omitted entirely when there's no genuine narration).
        if narrationEnabled, let lastWorkDone, loadedNodeID == node.id {
          section("Last Work Done") {
            VStack(alignment: .leading, spacing: 4) {
              findableText(lastWorkDone, anchor: .narration).prose()
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
                LooseEndRow(view: view, loadProvenance: model.provenance,
                            onLabel: model.setLooseEndLabel,
                            expandedLooseEndID: model.expandedLooseEndID, compact: false,
                            find: find)
                  .id(view.looseEnd.id)
              }
            }
          }
        }

        // RECENT ACTIVITY (GitHub-style rail timeline)
        section("Recent Activity") {
          if recentEvents.isEmpty {
            Text("No captured activity.").foregroundStyle(.secondary)
          } else {
            ActivityTimeline(events: recentEvents, find: find)
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
      isDescribing = false
      describeNote = nil
      let detail = model.detail(for: node)
      describable = model.isDescribable(node)
      recentEvents = detail.status.recentEvents
      looseEnds = detail.looseEnds
      if let id = model.expandedLooseEndID { withAnimation { proxy.scrollTo(id, anchor: .center) } }
      find.reset(nodeID: node.id,
                 document: NodeFindDocument.make(node: node, narration: nil,
                                                 looseEnds: looseEnds, events: recentEvents,
                                                 showsLooseEnds: showsLooseEnds))
      shareMarkdown = RecallMarkdown.render(node: node,
                                            narration: narrationEnabled ? model.cachedNarration(for: node, events: recentEvents) : nil,
                                            looseEnds: looseEnds, events: recentEvents, now: Date())
      guard narrationEnabled else { lastWorkDone = nil; isNarrating = false; return }
      if !isRefresh, let cached = model.cachedNarration(for: node, events: recentEvents) {
        lastWorkDone = cached
        find.reset(nodeID: node.id,
                   document: NodeFindDocument.make(node: node, narration: cached,
                                                   looseEnds: looseEnds, events: recentEvents,
                                                   showsLooseEnds: showsLooseEnds))
        return
      }
      isNarrating = true
      let prose = await model.narration(for: node, events: recentEvents, force: isRefresh)
      guard !Task.isCancelled else { return }   // superseded: new task owns state; don't touch isNarrating
      lastWorkDone = prose
      find.reset(nodeID: node.id,
                 document: NodeFindDocument.make(node: node,
                                                 narration: narrationEnabled ? prose : nil,
                                                 looseEnds: looseEnds, events: recentEvents,
                                                 showsLooseEnds: showsLooseEnds))
      shareMarkdown = RecallMarkdown.render(node: node, narration: prose,
                                            looseEnds: looseEnds, events: recentEvents, now: Date())
      isNarrating = false
    }
    .onChange(of: model.expandedLooseEndID) { _, id in
      guard let id else { return }
      withAnimation { proxy.scrollTo(id, anchor: .center) }
    }
    .onChange(of: find.scrollTarget) { _, anchor in
      guard let anchor else { return }
      withAnimation { proxy.scrollTo(anchor, anchor: .center) }
      find.scrollTarget = nil
    }
    }
    }
    .focusedSceneValue(\.nodeFind, find)
    .onExitCommand { if find.isPresented { find.dismiss() } }
  }

  @ViewBuilder private func section(_ title: LocalizedStringResource, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).sectionHeader()
      content()
    }
  }

  /// A text site that participates in find: highlighted when the query matches, plain otherwise,
  /// and always registered as a scroll target.
  @ViewBuilder private func findableText(_ text: String, anchor: FindAnchor) -> some View {
    let runs = find.runs(for: anchor, text: text)
    Group {
      if runs.isEmpty {
        Text(text)
      } else {
        HighlightedText(runs: runs, currentOffset: find.currentOffset(in: anchor))
      }
    }
    .findSite(anchor, find)
  }

  @ViewBuilder private var descriptionBlock: some View {
    VStack(alignment: .leading, spacing: 4) {
      if !node.description.isEmpty {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          findableText(node.description, anchor: .description).prose()
          if describable {
            Button { runDescribe() } label: { Image(systemName: "arrow.clockwise") }
              .buttonStyle(.borderless).controlSize(.small)
              .help("Regenerate description")
              .disabled(isDescribing)
          }
        }
      } else if describable {
        Button { runDescribe() } label: {
          Label("Generate description", systemImage: "sparkles")
        }
        .buttonStyle(.borderless).controlSize(.small)
        .disabled(isDescribing)
      }
      if loadedNodeID == node.id {
        if isDescribing { ProgressView().controlSize(.small) }
        if let describeNote {
          Text(describeNote).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .padding(.top, 2)
  }

  private func runDescribe() {
    describeNote = nil
    isDescribing = true
    Task {
      let outcome = await model.describeNode(node)
      guard loadedNodeID == node.id else { return }   // navigated away: drop the result
      isDescribing = false
      switch outcome {
      case .noSignal, .attemptedEmpty: describeNote = String(localized: "Nothing to summarize")
      case .wrote, .ineligible: break   // describeNote already cleared at entry
      }
    }
  }
}

private struct DetailLoadKey: Hashable { let nodeID: UUID; let token: Int }

/// A GitHub-style vertical-rail timeline: events grouped by day, a colored dot per event on a rail,
/// the source icon+color, the localized source label, and the summary. No avatars (single-user).
private struct ActivityTimeline: View {
  let events: [Event]
  var find: NodeFindState?

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
            TimelineRow(event: event, isLast: idx == items.count - 1, find: find)
          }
        }
      }
    }
  }
}

private struct TimelineRow: View {
  let event: Event
  let isLast: Bool
  var find: NodeFindState?

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
        summaryText
      }
      Spacer()
    }
  }

  @ViewBuilder private var summaryText: some View {
    let anchor = FindAnchor.event(event.id)
    let runs = find?.runs(for: anchor, text: event.summary) ?? []
    Group {
      if runs.isEmpty {
        Text(event.summary)
      } else {
        HighlightedText(runs: runs, currentOffset: find?.currentOffset(in: anchor))
      }
    }
    .prose()
    .findSite(anchor, find)
  }

  @ViewBuilder private func sourceIcon(_ sourceStyle: SourceStyle) -> some View {
    switch AppearanceIcon.parse(sourceStyle.icon) {
    case .sfSymbol(let symbolName): Image(systemName: symbolName)
    case .emoji(let emoji):    Text(emoji)
    case nil:              Image(systemName: "circle.fill")
    }
  }
}
