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
      Section("Smart Lists") {
        smartRow(.whatsNext, count: model.lists.whatsNext.count)
        smartRow(.dormant, count: model.lists.dormant.count)
        smartRow(.recentlyActive, count: model.lists.recentlyActive.count)
      }
      Section("Projects") {
        OutlineGroup(model.forest, children: \.childrenIfAny) { item in
          Label(item.node.name, systemImage: symbol(for: item.node.kind))
            .tag(SidebarSelection.node(item.node.id))
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) { StatusFooter() }
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
    }
    .tag(SidebarSelection.smartList(kind))
  }

  private func symbol(for kind: String) -> String {
    switch kind {
    case "domain": return "folder"
    case "strand": return "arrow.triangle.branch"
    default: return "shippingbox"
    }
  }
}

/// `OutlineGroup`'s recursive-children API needs `nil` to mark a leaf; `NodeForestNode.children`
/// is a plain (non-optional, possibly-empty) array, so adapt it here rather than in PensieveKit.
extension NodeForestNode {
  fileprivate var childrenIfAny: [NodeForestNode]? { children.isEmpty ? nil : children }
}

/// Reuses the read-only heartbeat kernel for a tiny liveness dot at the sidebar's foot.
private struct StatusFooter: View {
  @State private var snapshot = MonitorSnapshot(status: .notSetUp, lastCaptureAt: nil,
                                                spoolPending: 0, eventCount: 0, looseEndCount: 0)
  private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text(label).font(.caption).foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .onAppear(perform: refresh)
    .onReceive(tick) { _ in refresh() }
  }
  private func refresh() {
    snapshot = MonitorSnapshot.gather(canonicalURL: Stores.canonicalURL, spoolURL: Stores.spoolURL)
  }
  private var color: Color {
    switch snapshot.status { case .active: return .green; case .idle: return .secondary; case .notSetUp: return .orange }
  }
  private var label: String {
    switch snapshot.status { case .active: return "capturing"; case .idle: return "idle"; case .notSetUp: return "not set up" }
  }
}
