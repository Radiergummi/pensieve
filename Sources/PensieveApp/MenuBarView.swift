// Sources/PensieveApp/MenuBarView.swift
import SwiftUI
import PensieveKit

/// App-side UI mapping for the heartbeat status (kept out of PensieveKit — SF Symbol names and
/// display words are UI concerns, like SmartListKind's title/symbol).
extension MonitorSnapshot.Status {
  var glyph: String {
    switch self {
    case .active: return "circle.fill"
    case .idle: return "circle"
    case .notSetUp: return "circle.slash"
    }
  }
  var label: String {
    switch self {
    case .active: return "Active"
    case .idle: return "Idle"
    case .notSetUp: return "Not set up"
    }
  }
}

/// The menu-bar popover content: capture heartbeat + a short What's Next glance. Reads the shared
/// AppModel and renders only — all data is from the tested MonitorSnapshot / SmartLists kernels.
struct MenuBarView: View {
  @ObservedObject var model: AppModel

  private static let maxRows = 5

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      heartbeat
      Divider()
      Text("What's Next").font(.caption).foregroundStyle(.secondary)
      whatsNext
      Divider()
      footer
    }
    .padding(12)
    .frame(width: 300)
    .task { model.refresh() }   // fresh on open (the 3 s Timer is suppressed while the menu is up)
  }

  @ViewBuilder private var heartbeat: some View {
    HStack(spacing: 6) {
      Image(systemName: model.snapshot.status.glyph)
      Text(statusLine).font(.callout).fontWeight(.medium)
      Spacer()
      Text("\(model.snapshot.looseEndCount) open").font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var whatsNext: some View {
    let items = Array(model.lists.whatsNext.prefix(Self.maxRows))
    if items.isEmpty {
      Text("Nothing queued").font(.callout).foregroundStyle(.secondary)
    } else {
      ForEach(items, id: \.project.id) { item in
        HStack {
          Text(item.project.name).lineLimit(1)
          Spacer()
          Text("\(item.openLooseEnds) open · \(item.daysDormant)d dormant")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder private var footer: some View {
    HStack {
      Button("Refresh") { Task { await model.refreshNow() } }
      Spacer()
      Button("Quit") { NSApplication.shared.terminate(nil) }
    }
  }

  private var statusLine: String {
    var s = model.snapshot.status.label
    if let last = model.snapshot.lastCaptureAt {
      s += " · captured \(Self.relativeAge(last))"
    }
    return s
  }

  /// Local formatter instance (no shared mutable static — Swift 6 concurrency rule).
  private static func relativeAge(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
  }
}
