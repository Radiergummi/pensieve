// Sources/PensieveApp/ContentListView.swift
import SwiftUI
import PensieveKit

struct ContentListView: View {
  var model: AppModel
  // A focused leaf's loose ends, loaded off-`body` via `.task` (never a DB query in `body`).
  @State private var looseEnds: [LooseEndView] = []
  @State private var reviewItems: [LooseEndView] = []
  @State private var triageItems: [LooseEndView] = []
  @State private var completedItems: [LooseEndView] = []
  /// The feed row the detail pane is currently showing. Local to the column, not on `AppModel`:
  /// it is a cursor into this list, and a recall window opened from here must not inherit it.
  @State private var focusedFeedID: UUID?
  @Environment(\.undoManager) private var undoManager

  var body: some View {
    Group {
      if model.isSearching {
        searchResultsList()
          .navigationTitle(Text("Search"))
      } else {
        normalContent
      }
    }
    // Above every list this column shows, search results included: `runSearch()` scopes on the same
    // `visibleNodeIDs()` the lists do, so a Focus-shortened result set needs the notice most of all.
    .safeAreaInset(edge: .top, spacing: 0) {
      FocusFilterBanner(context: model.activeFocusContext)
    }
  }

  @ViewBuilder private var normalContent: some View {
    let kind = model.middleKind()
    Group {
      switch kind {
      case .nodes(let items): nodeList(items)
      case .looseEndsOf: looseEndList()
      case .reviewSuggestions: reviewList()
      case .triage: crossNodeList(triageItems, showsStatusBadge: false)
      case .completed: crossNodeList(completedItems, showsStatusBadge: true)
      }
    }
    .navigationTitle(model.middleTitle)
    .navigationSubtitle(subtitle(for: kind))
    // Load the focused leaf's loose ends. Re-runs on selection change AND ⌘R (refreshToken),
    // mirroring DetailView's off-body load. Non-leaf kinds clear the list.
    .task(id: MiddleLoadKey(kind: kind, token: model.refreshToken,
                            looseEndRevision: model.looseEndRevision)) {
      switch kind {
      case .looseEndsOf(let id): looseEnds = model.looseEnds(forNode: id)
      case .reviewSuggestions: reviewItems = model.reviewItems()
      case .triage: triageItems = model.triageItems()
      case .completed: completedItems = model.completedItems()
      case .nodes: looseEnds = []; reviewItems = []; triageItems = []; completedItems = []
      }
    }
    // Published ONLY while a feed is showing, so the Edit-menu verbs are disabled elsewhere rather
    // than acting on a stale selection. `.focusedSceneValue`, matching `NodeFindState`: a menu verb
    // acts on the focused SCENE's selected row, so it must survive the pointer moving into the detail
    // pane — plain `.focusedValue` disabled the verbs as soon as view focus left this List.
    .focusedSceneValue(\.looseEndSelection, feedSelection(for: kind))
  }

  @ViewBuilder private func searchResultsList() -> some View {
    List {
      searchScopePicker()
      if let pinned = model.pinnedTopHit {
        Section(header: Text("Top Hit")) { searchRow(pinned) }
      }
      if !model.searchHits.isEmpty {
        Section(header: Text("Results")) {
          ForEach(model.searchHits) { hit in searchRow(hit) }
        }
      }
      PassageResultsSection(hits: model.passageHits) { model.openPassage($0) }
    }
    .overlay { searchEmptyState() }
  }

  /// "Nothing matched" and "the index isn't built" must not look the same — since BM25 became the
  /// only retrieval path, an unbuilt index would otherwise read as "you never worked on that".
  /// Also gated on `passageHits`: this overlay covers the whole List, so without that check a query
  /// that matched only a conversation passage (no ranked hit, no pinned node) would have its section
  /// hidden underneath a "nothing matched" card.
  @ViewBuilder private func searchEmptyState() -> some View {
    if model.searchHits.isEmpty && model.pinnedTopHit == nil && model.passageHits.isEmpty {
      switch model.searchIndexState {
      case .building:
        ContentUnavailableView("Building the search index…", systemImage: "clock.arrow.circlepath")
      case .absent:
        ContentUnavailableView("The search index has not been built yet.",
                               systemImage: "exclamationmark.magnifyingglass")
      case .ready:
        ContentUnavailableView.search(text: model.searchText)
      }
    }
  }

  // Scope control lives here (not `.searchScopes`) so it exists only while search is on screen.
  @ViewBuilder private func searchScopePicker() -> some View {
    Picker("", selection: Binding(get: { model.searchScope }, set: { model.searchScope = $0 })) {
      Text("Active").tag(AppModel.SearchScope.active)
      Text("Include Archived & Closed").tag(AppModel.SearchScope.all)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .listRowSeparator(.hidden)
  }

  /// One row for every hit, branching on `kind` — there is one hit type now, so the old
  /// per-section row builders collapse into this.
  @ViewBuilder private func searchRow(_ hit: SearchHit) -> some View {
    Button { model.selectSearchHit(hit) } label: {
      HStack(spacing: 10) {
        if hit.kind == .node, let resultNode = model.node(hit.nodeID) {
          NodeBadge(node: resultNode, size: 22)
        }
        VStack(alignment: .leading, spacing: 2) {
          if hit.kind == .node {
            // The node IS the hit — lead with its name, and show what matched below it.
            Text(hit.nodeName)
            SnippetText(snippet: hit.snippet).font(.caption).foregroundStyle(.secondary)
          } else {
            // A loose end or an event — lead with the owning node so the hit is placeable.
            Text(hit.nodeName).font(.caption).foregroundStyle(.secondary)
            SnippetText(snippet: hit.snippet)
          }
        }
        // The `Spacer()` is hoisted out of the archived branch: both badges can show on one row, and
        // pushing twice would leave a gap between them.
        if hit.isArchived || hit.status.isClosed { Spacer() }
        if hit.isArchived { ArchivedBadge() }
        if hit.status.isClosed { LooseEndStatusBadge(status: hit.status) }
      }
      .rowHitArea()
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder private func nodeList(_ items: [Node]) -> some View {
    List(items, selection: Binding(
      get: { model.selectedNodeID },
      set: { if let id = $0 { model.selectMiddleNode(id) } })) { node in
      HStack(spacing: 10) {
        NodeBadge(node: node, size: 26)
        VStack(alignment: .leading, spacing: 2) {
          Text(node.name)
          // Was `kindLabel`, which read "Project / Project / Project" down the whole column and so
          // discriminated nothing. Recency and volume are what tell these rows apart.
          NodeRowMeta(facts: model.nodeRowFacts[node.id])
        }
      }
      .tag(node.id)
      .contextMenu { NodeContextMenu(model: model, node: node) }
    }
    .overlay {
      if items.isEmpty { ContentUnavailableView("Nothing here", systemImage: "tray") }
    }
  }

  @ViewBuilder private func looseEndList() -> some View {
    List {
      ForEach(looseEnds, id: \.looseEnd.id) { view in
        LooseEndRow(view: view, loadProvenance: model.provenance, onLabel: model.setLooseEndLabel,
                    displaySummary: model.displayed(field: .looseEndText,
                                                    sourceText: view.looseEnd.text),
                    onTranslate: { text in await model.translate(field: .looseEndText, sourceText: text) },
                    // A childless focused leaf shows its loose ends HERE and the detail pane then
                    // renders no Loose Ends section (the one-home rule), so without this its ends
                    // would be resolvable from nowhere but the global triage feed.
                    onResolve: { id, status, previous, previousStamp in
                      model.resolveLooseEnd(id, status, previous: previous,
                                            previousResolvedAt: previousStamp,
                                            undoManager: undoManager)
                    },
                    compact: true)
      }
    }
    .overlay {
      if looseEnds.isEmpty { ContentUnavailableView("None open", systemImage: "checkmark.circle") }
    }
  }

  @ViewBuilder private func reviewList() -> some View {
    List {
      ForEach(reviewItems, id: \.looseEnd.id) { view in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            if let name = model.node(view.looseEnd.nodeID)?.name {
              Text(name).font(.caption).foregroundStyle(.secondary)
            }
            // This queue deliberately keeps closed items (spec D9: a closed end is still labellable),
            // so it has to say which ones are closed — otherwise handled work is indistinguishable
            // from live work in the one list whose whole job is judging items.
            if view.looseEnd.status.isClosed {
              Spacer()
              LooseEndStatusBadge(status: view.looseEnd.status)
            }
          }
          LooseEndRow(view: view, loadProvenance: model.provenance, onLabel: model.setLooseEndLabel,
                      displaySummary: model.displayed(field: .looseEndText,
                                                      sourceText: view.looseEnd.text),
                      onTranslate: { text in await model.translate(field: .looseEndText, sourceText: text) },
                      compact: true)
        }
      }
    }
    .overlay {
      if reviewItems.isEmpty {
        ContentUnavailableView("No suggestions to review", systemImage: "checklist")
      }
    }
  }

  /// The two cross-node loose-end feeds. Rows carry the owning node's name (they come from
  /// everywhere) and offer the resolve verbs; the Completed feed additionally badges each row with
  /// the verb that closed it, which is the only consumer that distinguishes done from dropped.
  ///
  /// A sibling of `reviewList()` rather than a generalization of it: that list is find-unscoped,
  /// resolve-less and has its own empty state, and folding three surfaces into one builder with
  /// three flags would be harder to read than one small duplicate.
  @ViewBuilder private func crossNodeList(_ items: [LooseEndView],
                                          showsStatusBadge: Bool) -> some View {
    // A `List(selection:)` rather than plain rows: ↑↓ then walks the queue and the detail pane
    // follows, which is the whole burn-down loop. It also avoids fighting `LooseEndRow`'s own tap,
    // which toggles its inline provenance — a row-level `.onTapGesture` would swallow that.
    List(selection: Binding(
      get: { focusedFeedID },
      set: { newValue in
        focusedFeedID = newValue
        if let newValue, let match = items.first(where: { $0.looseEnd.id == newValue }) {
          model.focusLooseEnd(match.looseEnd)
        }
      })) {
      ForEach(items, id: \.looseEnd.id) { view in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            if let name = model.node(view.looseEnd.nodeID)?.name {
              Text(name).font(.caption).foregroundStyle(.secondary)
            }
            if showsStatusBadge {
              Spacer()
              LooseEndStatusBadge(status: view.looseEnd.status)
            }
          }
          LooseEndRow(view: view, loadProvenance: model.provenance, onLabel: model.setLooseEndLabel,
                      displaySummary: model.displayed(field: .looseEndText,
                                                      sourceText: view.looseEnd.text),
                      onTranslate: { text in await model.translate(field: .looseEndText, sourceText: text) },
                      onResolve: { id, status, previous, previousStamp in
                        model.resolveLooseEnd(id, status, previous: previous,
                                            previousResolvedAt: previousStamp,
                                            undoManager: undoManager)
                      },
                      compact: true)
        }
        .tag(view.looseEnd.id)
      }
    }
    .overlay {
      if items.isEmpty {
        if showsStatusBadge {
          ContentUnavailableView("Nothing completed yet", systemImage: "checkmark.circle")
        } else {
          ContentUnavailableView("No open loose ends", systemImage: "tray")
        }
      }
    }
  }

  /// The focused-value payload for the Edit-menu verbs: the selected feed row, or nil when the middle
  /// column is showing anything else.
  private func feedSelection(for kind: MiddleKind) -> LooseEndSelection? {
    let items: [LooseEndView]
    switch kind {
    case .triage: items = triageItems
    case .completed: items = completedItems
    case .nodes, .looseEndsOf, .reviewSuggestions: return nil
    }
    guard let id = focusedFeedID, let match = items.first(where: { $0.looseEnd.id == id })
    else { return nil }
    let previous = match.looseEnd.status
    let previousStamp = match.looseEnd.resolvedAt
    return LooseEndSelection(looseEndID: id, status: previous) { newStatus in
      model.resolveLooseEnd(id, newStatus, previous: previous,
                            previousResolvedAt: previousStamp, undoManager: undoManager)
    }
  }

  private func subtitle(for kind: MiddleKind) -> String {
    switch kind {
    case .nodes(let items):
      if case .node = model.sidebarSelection { return String(localized: "\(items.count) strands") }
      return String(localized: "\(model.projectCount) Projects")
    case .looseEndsOf:
      return String(localized: "\(looseEnds.count) loose ends")
    case .reviewSuggestions:
      return String(localized: "\(reviewItems.count) to review")
    case .triage:
      return String(localized: "\(triageItems.count) open")
    case .completed:
      return String(localized: "\(completedItems.count) closed")
    }
  }
}

/// A small trailing marker on a search row whose owning node is archived, so archived work is never
/// mistaken for live work. Rendered only when the Include Archived scope surfaced the row.
struct ArchivedBadge: View {
  var body: some View {
    Text("Archived")
      .font(.caption2)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(.quaternary, in: Capsule())
      .foregroundStyle(.secondary)
  }
}

/// Renders a grounded snippet with the matched run highlighted. A `Snippet` is the N=1 case of
/// `FindRun`, so this delegates to the app's one highlight renderer (in its `.snippet` style —
/// bold + accent, no background, matching this view's shipped look) rather than building a second.
struct SnippetText: View {
  let snippet: Snippet
  var body: some View {
    HighlightedText(runs: runs, style: .snippet).lineLimit(2)
  }

  /// `snippet.match` is `""` when nothing matched — omit the `.match` run entirely rather than
  /// emit an empty one, so `runs.isEmpty` still means "no match" for anyone who tests it later.
  private var runs: [FindRun] {
    guard !snippet.match.isEmpty else { return [.plain(snippet.leading), .plain(snippet.trailing)] }
    return [.plain(snippet.leading), .match(snippet.match), .plain(snippet.trailing)]
  }
}

extension View {
  /// A `.plain` Button only accepts clicks inside its label's bounds, so a short label (a one-word
  /// hit) leaves most of the row dead. Widen the label to the full row and make it all hittable.
  func rowHitArea() -> some View {
    frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
  }
}

/// A Hashable `.task` id for the middle. Derived from `MiddleKind` WITHOUT hashing the node array —
/// only the leaf id, the refresh token and the loose-end revision matter for reloading loose ends.
/// The revision is what makes a resolved row actually leave the feed: `refresh()` does not bump
/// `refreshToken` (that means ⌘R), so without it the write landed and the list never reloaded.
private struct MiddleLoadKey: Hashable {
  enum Tag: Hashable { case nodes, looseEnds(UUID), review, triage, completed }
  let tag: Tag
  let token: Int
  let looseEndRevision: Int
  init(kind: MiddleKind, token: Int, looseEndRevision: Int) {
    self.looseEndRevision = looseEndRevision
    switch kind {
    case .looseEndsOf(let id): tag = .looseEnds(id)
    case .reviewSuggestions: tag = .review
    case .triage: tag = .triage
    case .completed: tag = .completed
    case .nodes: tag = .nodes
    }
    self.token = token
  }
}
