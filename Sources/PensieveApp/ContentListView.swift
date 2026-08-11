// Sources/PensieveApp/ContentListView.swift
import SwiftUI
import PensieveKit

struct ContentListView: View {
  var model: AppModel
  // A focused leaf's loose ends, loaded off-`body` via `.task` (never a DB query in `body`).
  @State private var looseEnds: [LooseEndView] = []
  @State private var reviewItems: [LooseEndView] = []

  var body: some View {
    Group {
      if model.isSearching {
        searchResultsList()
          .navigationTitle(Text("Search"))
      } else {
        normalContent
      }
    }
  }

  @ViewBuilder private var normalContent: some View {
    let kind = model.middleKind()
    Group {
      switch kind {
      case .nodes(let items): nodeList(items)
      case .looseEndsOf: looseEndList()
      case .reviewSuggestions: reviewList()
      }
    }
    .navigationTitle(model.middleTitle)
    .navigationSubtitle(subtitle(for: kind))
    // Load the focused leaf's loose ends. Re-runs on selection change AND ⌘R (refreshToken),
    // mirroring DetailView's off-body load. Non-leaf kinds clear the list.
    .task(id: MiddleLoadKey(kind: kind, token: model.refreshToken)) {
      switch kind {
      case .looseEndsOf(let id): looseEnds = model.looseEnds(forNode: id)
      case .reviewSuggestions: reviewItems = model.reviewItems()
      case .nodes: looseEnds = []; reviewItems = []
      }
    }
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
    }
    .overlay { searchEmptyState() }
  }

  /// "Nothing matched" and "the index isn't built" must not look the same — since BM25 became the
  /// only retrieval path, an unbuilt index would otherwise read as "you never worked on that".
  @ViewBuilder private func searchEmptyState() -> some View {
    if model.searchHits.isEmpty && model.pinnedTopHit == nil {
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
      Text("Include Archived").tag(AppModel.SearchScope.all)
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
        if hit.isArchived { Spacer(); ArchivedBadge() }
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
          Text(AppearanceStyle.kindLabel(node.kind)).font(.caption).foregroundStyle(.secondary)
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
          if let name = model.node(view.looseEnd.nodeID)?.name {
            Text(name).font(.caption).foregroundStyle(.secondary)
          }
          LooseEndRow(view: view, loadProvenance: model.provenance, onLabel: model.setLooseEndLabel,
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

  private func subtitle(for kind: MiddleKind) -> String {
    switch kind {
    case .nodes(let items):
      if case .node = model.sidebarSelection { return String(localized: "\(items.count) strands") }
      return String(localized: "\(model.projectCount) Projects")
    case .looseEndsOf:
      return String(localized: "\(looseEnds.count) loose ends")
    case .reviewSuggestions:
      return String(localized: "\(reviewItems.count) to review")
    }
  }
}

/// A small trailing marker on a search row whose owning node is archived, so archived work is never
/// mistaken for live work. Rendered only when the Include Archived scope surfaced the row.
private struct ArchivedBadge: View {
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
/// only the leaf id + refresh token matter for reloading loose ends.
private struct MiddleLoadKey: Hashable {
  enum Tag: Hashable { case nodes, looseEnds(UUID), review }
  let tag: Tag
  let token: Int
  init(kind: MiddleKind, token: Int) {
    switch kind {
    case .looseEndsOf(let id): tag = .looseEnds(id)
    case .reviewSuggestions: tag = .review
    case .nodes: tag = .nodes
    }
    self.token = token
  }
}
