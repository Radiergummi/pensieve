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
  @State private var closedLooseEnds: [LooseEndView] = []
  @Environment(\.undoManager) private var undoManager
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
      // `nodeID == nil` = the detail load hasn't landed yet. The bar still shows, so a ⌘F fired
      // during the load is not swallowed; it reports "No matches" for the moment, then the load's
      // `resetFind` hands it the real document and re-runs the query against it.
      if find.isPresented, find.nodeID == nil || find.nodeID == node.id { FindBar(find: find) }
      ScrollViewReader { proxy in
      ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // WHAT IT IS — name, the adaptive state line, description.
        HStack(alignment: .top, spacing: 12) {
          NodeBadge(node: node, size: 44)
          VStack(alignment: .leading, spacing: 4) {
            findableText(node.name, anchor: .nodeName).font(.largeTitle).bold()
            NodeMetaLine(node: node, facts: model.nodeRowFacts[node.id])
            descriptionBlock
          }
        }

        // LOOSE ENDS — cited and verbatim, so they come BEFORE the best-effort prose below.
        // Omitted when the middle column already shows them (the one-home rule).
        if showsLooseEnds {
          section("Loose Ends") {
            if looseEnds.isEmpty {
              Text("None open.").foregroundStyle(.secondary)
            } else {
              ForEach(looseEnds, id: \.looseEnd.id) { view in
                LooseEndRow(view: view, loadProvenance: model.provenance,
                            onLabel: model.setLooseEndLabel,
                            displaySummary: model.displayed(field: .looseEndText,
                                                            sourceText: view.looseEnd.text),
                            onTranslate: { text in await model.translate(field: .looseEndText, sourceText: text) },
                            onResolve: { id, status, previous in
                              model.resolveLooseEnd(id, status, previous: previous,
                                                    undoManager: undoManager)
                            },
                            expandedLooseEndID: model.expandedLooseEndID, compact: false,
                            find: find)
                  .id(view.looseEnd.id)
              }
            }
          }
        }

        // RECAP — deliberately headerless. A caps header announces a slot, so an empty slot reads as
        // a failure; narration is best-effort and returns nil, and its absence must read as nothing.
        // The attribution line is a trust marker separating best-effort prose from cited content and
        // is NOT optional.
        if narrationEnabled, let lastWorkDone, loadedNodeID == node.id {
          VStack(alignment: .leading, spacing: 4) {
            Divider()
            findableText(lastWorkDone, anchor: .narration).prose().padding(.top, 4)
            Label("Generated summary", systemImage: "sparkles")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        } else if narrationEnabled, isNarrating, loadedNodeID == node.id {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Label("Generated summary", systemImage: "sparkles")
              .font(.caption2)
              .foregroundStyle(.secondary)
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

        // THE RECORD, collapsed. LAST in the pane, which is load-bearing: in-node ⌘F indexes
        // per-loose-end slots in on-screen order, so closed rows placed inside the Loose Ends
        // section above would sit before `.narration` and every `.event` in the document while
        // rendering after them — the exact slice-A × in-node-find defect. Rendering last keeps the
        // deferral of find-indexing (spec §7.1) honest and compatible.
        //
        // Rendered only when non-empty: an always-present "Done · 0" would announce a slot that is
        // usually empty, the same failure the recap's removed caps header had. Gated on
        // `showsLooseEnds` so a childless focused strand does not grow a stray section.
        if showsLooseEnds, !closedLooseEnds.isEmpty {
          DisclosureGroup {
            ForEach(closedLooseEnds, id: \.looseEnd.id) { view in
              HStack(alignment: .top, spacing: 8) {
                LooseEndStatusBadge(status: view.looseEnd.status)
                LooseEndRow(view: view, loadProvenance: model.provenance,
                            onLabel: model.setLooseEndLabel,
                            displaySummary: model.displayed(field: .looseEndText,
                                                            sourceText: view.looseEnd.text),
                            onTranslate: { text in await model.translate(field: .looseEndText, sourceText: text) },
                            onResolve: { id, status, previous in
                              model.resolveLooseEnd(id, status, previous: previous,
                                                    undoManager: undoManager)
                            },
                            compact: false)
              }
            }
          } label: {
            Text("Done · \(closedLooseEnds.count)").font(.callout).foregroundStyle(.secondary)
          }
          .padding(.top, 4)
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
      closedLooseEnds = model.closedLooseEnds(forNode: node.id)
      if let id = model.expandedLooseEndID { withAnimation { proxy.scrollTo(id, anchor: .center) } }
      resetFind(narration: nil)
      // Computed once: both the pre-generation share markdown and the cached fast path below read
      // the same store lookup, so there is exactly one value in flight, not two independent reads.
      let cachedDisplay = narrationEnabled ? model.cachedDisplayNarration(for: node, events: recentEvents) : nil
      shareMarkdown = RecallMarkdown.render(node: node, narration: cachedDisplay,
                                            looseEnds: looseEnds, events: recentEvents, now: Date(),
                                            translatedLooseEndText: translatedLooseEndText)
      guard narrationEnabled else { lastWorkDone = nil; isNarrating = false; return }
      if !isRefresh, let cached = cachedDisplay {
        lastWorkDone = cached
        resetFind(narration: cached)
        return
      }
      isNarrating = true
      let prose = await model.displayNarration(for: node, events: recentEvents, force: isRefresh)
      guard !Task.isCancelled else { return }   // superseded: new task owns state; don't touch isNarrating
      lastWorkDone = prose
      resetFind(narration: narrationEnabled ? prose : nil)
      shareMarkdown = RecallMarkdown.render(node: node, narration: prose,
                                            looseEnds: looseEnds, events: recentEvents, now: Date(),
                                            translatedLooseEndText: translatedLooseEndText)
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
    // An on-demand translation landed: repaint with the new text (each row's `displaySummary`
    // input is recomputed above), rebuild the find document so ⌘F sees it too, and rebuild the share
    // markdown so Share/Copy exports what is now displayed — deliberately NOT a `.task(id:)` rerun,
    // which is keyed on `refreshToken` (⌘R) and would force-regenerate the narration through the LLM
    // for a change that touched no canonical data.
    .onChange(of: model.translationRevision) { _, _ in
      resetFind(narration: lastWorkDone)
      shareMarkdown = RecallMarkdown.render(node: node, narration: lastWorkDone,
                                            looseEnds: looseEnds, events: recentEvents, now: Date(),
                                            translatedLooseEndText: translatedLooseEndText)
    }
    }
    .scrollEdgeEffectStyle(.soft, for: .top)
    }
    .focusedSceneValue(\.nodeFind, find)
    .onChange(of: find.isPresented) { _, presented in
      // Opening the bar is what pays for the transcript sweep: it reads every referenced transcript
      // off the main actor, so nothing loads it until the user actually asks to find something.
      if presented { find.startSweep(looseEnds: looseEnds, loader: model.provenanceLoader) }
    }
    .onExitCommand { if find.isPresented { find.dismiss() } }
  }

  /// Rebuilds the find document for what is currently on screen, then restarts the transcript sweep.
  /// The two belong together: `reset` rebuilds every provenance slot as unresolved AND cancels the
  /// in-flight sweep, so a same-node rebuild (⌘R, narration arriving) would otherwise drop the
  /// transcript matches the sweep had already filled with nothing left to refill them. Restarting is
  /// cheap — the loader serves an unchanged transcript from its cache and reports "nothing to do".
  @MainActor private func resetFind(narration: String?) {
    find.reset(nodeID: node.id,
               document: NodeFindDocument.make(node: node, narration: narration,
                                               looseEnds: looseEnds, events: recentEvents,
                                               showsLooseEnds: showsLooseEnds,
                                               translatedLooseEndText: translatedLooseEndText))
    find.startSweep(looseEnds: looseEnds, loader: model.provenanceLoader)
  }

  /// What every loose end's row actually renders (`LooseEndRow`'s `displaySummary` input, built the
  /// same way) — the on-demand translation when one is stored, else the English original. Shared by
  /// the find document and the share markdown so neither can disagree with what is on screen.
  private var translatedLooseEndText: [UUID: String] {
    Dictionary(uniqueKeysWithValues: looseEnds.map {
      ($0.looseEnd.id, model.displayed(field: .looseEndText, sourceText: $0.looseEnd.text))
    })
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
