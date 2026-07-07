// Sources/PensieveApp/SidebarView.swift
import SwiftUI
import PensieveKit

struct SidebarView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    List(selection: Binding(
      get: { model.sidebarSelection },
      set: { newValue in
        model.sidebarSelection = newValue
        // Selecting a smart list clears the detail until a middle-column row is picked;
        // selecting a tree node jumps detail straight to it.
        if case .node(let id) = newValue { model.selectedNodeID = id }
        else { model.selectedNodeID = nil }
      })) {
      Label("Briefing", systemImage: "sun.max")
        .tag(SidebarSelection.briefing)
      Section("Smart Lists") {
        smartRow(.whatsNext, count: model.lists.whatsNext.count)
        smartRow(.dormant, count: model.lists.dormant.count)
        smartRow(.recentlyActive, count: model.lists.recentlyActive.count)
      }
      Section("Projects") {
        OutlineGroup(model.forest, children: \.childrenIfAny) { item in
          Group {
            if model.renamingNodeID == item.node.id {
              NodeNameField(model: model, node: item.node)
            } else {
              Label(item.node.name, systemImage: symbol(for: item.node.kind))
            }
          }
          .tag(SidebarSelection.node(item.node.id))
          .contextMenu { NodeContextMenu(model: model, node: item.node) }
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) { StatusFooter(snapshot: model.snapshot) }
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

  private func symbol(for kind: String) -> String {
    switch kind {
    case "domain": return "folder"
    case "strand": return "arrow.triangle.branch"
    case "concept": return "lightbulb"
    case "initiative": return "flag"
    case "task": return "checklist"
    case "topic": return "tag"
    default: return "shippingbox"   // project + any unknown kind
    }
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
    HStack(spacing: 6) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text(label).font(.caption).foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
  }
  private var color: Color {
    switch snapshot.status { case .active: return .green; case .idle: return .secondary; case .notSetUp: return .orange }
  }
  private var label: String {
    switch snapshot.status {
    case .active: return String(localized: "capturing")
    case .idle: return String(localized: "idle")
    case .notSetUp: return String(localized: "not set up")
    }
  }
}
