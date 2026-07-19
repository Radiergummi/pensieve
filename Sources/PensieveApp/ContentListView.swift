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
    let r = model.searchResults
    List {
      // Scope control lives here (not `.searchScopes`) so it exists only while search is on screen.
      Picker("", selection: Binding(get: { model.searchScope }, set: { model.searchScope = $0 })) {
        Text("Active").tag(AppModel.SearchScope.active)
        Text("Include Archived").tag(AppModel.SearchScope.all)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .listRowSeparator(.hidden)

      if !r.nodes.isEmpty {
        Section(header: Text("Projects")) {
          ForEach(r.nodes) { hit in
            Button { model.selectSearchNode(hit.id) } label: {
              HStack(spacing: 10) {
                if let n = model.node(hit.id) { NodeBadge(node: n, size: 22) }
                VStack(alignment: .leading, spacing: 2) {
                  switch hit.matchedField {
                  case .name:
                    // The match is in the name — the snippet IS the highlighted name.
                    SnippetText(snippet: hit.snippet)
                    Text(AppearanceStyle.kindLabel(hit.kind)).font(.caption).foregroundStyle(.secondary)
                  case .description:
                    // Matched only in the description — lead with the node name so the hit is
                    // identifiable, and show the description snippet (why it matched) below.
                    Text(hit.name)
                    SnippetText(snippet: hit.snippet).font(.caption).foregroundStyle(.secondary)
                  }
                }
                if hit.isArchived { Spacer(); ArchivedBadge() }
              }
              .rowHitArea()
            }
            .buttonStyle(.plain)
          }
        }
      }
      if !r.looseEnds.isEmpty {
        Section(header: Text("Loose Ends")) {
          ForEach(r.looseEnds) { hit in
            Button { model.selectSearchLooseEnd(hit) } label: {
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                  Text(hit.nodeName).font(.caption).foregroundStyle(.secondary)
                  if hit.isArchived { ArchivedBadge() }
                }
                SnippetText(snippet: hit.snippet)
              }
              .rowHitArea()
            }
            .buttonStyle(.plain)
          }
        }
      }
      if !model.semanticHits.isEmpty {
        Section(header: Text("Related")) {
          ForEach(model.semanticHits) { hit in
            Button { model.selectSemanticHit(hit) } label: {
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                  Text(hit.nodeName).font(.caption).foregroundStyle(.secondary)
                  if hit.isArchived { ArchivedBadge() }
                }
                Text(hit.title).lineLimit(2)
              }
              .rowHitArea()
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .overlay {
      if r.isEmpty && model.semanticHits.isEmpty { ContentUnavailableView.search(text: model.searchText) }
    }
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
        LooseEndRow(view: view, loadProvenance: model.provenance, onLabel: model.setLooseEndLabel)
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
          LooseEndRow(view: view, loadProvenance: model.provenance, onLabel: model.setLooseEndLabel)
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

/// Renders a grounded snippet with the matched run highlighted — three Text runs, zero index math.
struct SnippetText: View {
  let snippet: Snippet
  var body: some View {
    (Text(snippet.leading)
      + Text(snippet.match).bold().foregroundColor(.accentColor)
      + Text(snippet.trailing))
      .lineLimit(2)
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
