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
    case .active: return String(localized: "Active")
    case .idle: return String(localized: "Idle")
    case .notSetUp: return String(localized: "Not set up")
    }
  }
}

/// The menu-bar popover content: capture heartbeat + a short What's Next glance. Reads the shared
/// AppModel and renders only — all data is from the tested MonitorSnapshot / SmartLists kernels.
struct MenuBarView: View {
  var model: AppModel
  @Environment(\.openWindow) private var openWindow

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
    .task { model.refreshGlance() }   // refresh on open; the always-mounted label is kept live between opens by the liveness watches
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
        Button {
          applyDeepLink(.node(item.project.id), model: model, openWindow: openWindow)
        } label: {
          HStack {
            Text(item.project.name).lineLimit(1)
            Spacer()
            Text("\(item.openLooseEnds) open · \(item.daysDormant)d dormant")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.plain)
      }
    }
  }

  @ViewBuilder private var footer: some View {
    HStack {
      Button("Open Pensieve") {
        applyDeepLink(.briefing, model: model, openWindow: openWindow)
      }
      Spacer()
      Button("Refresh") { Task { await model.refreshNow() } }
      Button("Quit") { NSApplication.shared.terminate(nil) }
    }
  }

  private var statusLine: String {
    var s = model.snapshot.status.label
    if let last = model.snapshot.lastCaptureAt {
      s += String(localized: " · captured \(Self.relativeAge(last))")
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

/// The always-mounted menu-bar label. Being always present, it is the reliable host for: wiring the
/// AppDelegate to the shared model, ensuring `start()` has run (so What's Next isn't empty even if
/// the main window never opened), and observing external deep links.
struct MenuBarLabel: View {
  var model: AppModel
  let appDelegate: AppDelegate
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Image(systemName: model.snapshot.status.glyph)
      .task {
        appDelegate.model = model   // flushes any URL that arrived before the model was wired
        model.start()               // idempotent (guarded in AppModel)
      }
      .onChange(of: model.pendingDeepLink) { _, link in
        guard let link else { return }
        applyDeepLink(link, model: model, openWindow: openWindow)
        model.pendingDeepLink = nil
      }
  }
}
