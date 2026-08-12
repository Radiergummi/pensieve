// Sources/PensieveApp/SidebarView.swift
import SwiftUI
import PensieveKit

struct SidebarView: View {
  var model: AppModel
  @AppStorage("sidebar.smartLists.expanded") private var smartExpanded = true
  @AppStorage("sidebar.projects.expanded") private var projectsExpanded = true
  @AppStorage("sidebar.archived.expanded") private var archivedExpanded = false

  var body: some View {
    List(selection: Binding(
      get: { model.sidebarSelection },
      set: { newValue in
        model.sidebarSelection = newValue
        // Selecting a smart list clears the detail until a middle-column row is picked;
        // selecting a tree node jumps detail straight to it.
        if case .node(let id) = newValue { model.selectedNodeID = id } else { model.selectedNodeID = nil }
      })) {
      Label("Briefing", systemImage: "sun.max")
        .tag(SidebarSelection.briefing)
      Label {
        HStack {
          Text("Review Suggestions")
          Spacer()
          if model.reviewCount > 0 {
            Text("\(model.reviewCount)").foregroundStyle(.secondary).monospacedDigit()
          }
        }
      } icon: {
        Image(systemName: "checklist").foregroundStyle(.orange)
      }
      .tag(SidebarSelection.reviewSuggestions)
      Section("Smart Lists", isExpanded: $smartExpanded) {
        smartRow(.whatsNext, count: model.lists.whatsNext.count)
        smartRow(.dormant, count: model.lists.dormant.count)
        smartRow(.recentlyActive, count: model.lists.recentlyActive.count)
      }
      Section("Projects", isExpanded: $projectsExpanded) {
        OutlineGroup(model.forest, children: \.childrenIfAny) { item in
          nodeRow(item)
        }
      }
      if !model.archivedForest.isEmpty {
        Section("Archived", isExpanded: $archivedExpanded) {
          OutlineGroup(model.archivedForest, children: \.childrenIfAny) { item in
            nodeRow(item)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .scrollEdgeEffectStyle(.soft, for: .top)
    .safeAreaInset(edge: .bottom) { StatusFooter(snapshot: model.snapshot) }
  }

  /// One tree row. Extracted with an explicit result type so the compiler doesn't have to
  /// type-check the nested Group/if + `.tag` + `.contextMenu` chain inside the OutlineGroup
  /// closure all at once ("unable to type-check this expression in reasonable time").
  @ViewBuilder private func nodeRow(_ item: NodeForestNode) -> some View {
    Label { Text(item.node.name) } icon: { NodeBadge(node: item.node, size: 18) }
      .tag(SidebarSelection.node(item.node.id))
      .contextMenu { NodeContextMenu(model: model, node: item.node) }
  }

  private func smartRow(_ kind: SmartListKind, count: Int) -> some View {
    Label {
      HStack {
        Text(kind.title)
        Spacer()
        Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
      }
    } icon: {
      Image(systemName: kind.symbol)
        .foregroundStyle(kind.color)
    }
    .tag(SidebarSelection.smartList(kind))
  }
}

/// `OutlineGroup`'s recursive-children API needs `nil` to mark a leaf; `NodeForestNode.children`
/// is a plain (non-optional, possibly-empty) array, so adapt it here rather than in PensieveKit.
extension NodeForestNode {
  fileprivate var childrenIfAny: [NodeForestNode]? { children.isEmpty ? nil : children }
}

/// A tiny liveness dot at the sidebar's foot, driven by the heartbeat snapshot `AppModel` already
/// polls — no second timer or store connection of its own.
private struct StatusFooter: View {
  let snapshot: MonitorSnapshot

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 7, height: 7)
        Text(label).font(.caption).foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, 12).padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(.bar)
  }
  private var color: Color {
    switch snapshot.status {
    case .active: return .green
    case .idle: return .secondary
    case .notSetUp: return .orange
    }
  }
  private var label: String {
    switch snapshot.status {
    case .active: return String(localized: "capturing")
    case .idle: return String(localized: "idle")
    case .notSetUp: return String(localized: "not set up")
    }
  }
}
