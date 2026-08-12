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
    .frame(width: 320)   // two-line rows need the room
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
        MenuBarRow(item: item, facts: model.nodeRowFacts[item.project.id]) {
          applyDeepLink(.node(item.project.id), model: model, openWindow: openWindow)
        }
      }
    }
  }

  @ViewBuilder private var footer: some View {
    HStack(spacing: 8) {
      // Full-width primary: German cannot truncate a button that owns the row. `.borderedProminent`
      // rather than a glass style — the `.window` popover surface is already system glass, so a
      // glass button on it would be glass on glass. This also picks up the system accent colour.
      Button("Open Pensieve") {
        applyDeepLink(.briefing, model: model, openWindow: openWindow)
      }
      .buttonStyle(.borderedProminent)
      .frame(maxWidth: .infinity)

      Menu {
        Button("Refresh") { Task { await model.refreshNow() } }
        Button("Quit") { NSApplication.shared.terminate(nil) }
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("More actions")
      .accessibilityLabel("More actions")
    }
  }

  private var statusLine: String {
    var statusLabel = model.snapshot.status.label
    if let last = model.snapshot.lastCaptureAt {
      statusLabel += String(localized: " · captured \(Self.relativeAge(last))")
    }
    return statusLabel
  }

  /// Local formatter instance (no shared mutable static — Swift 6 concurrency rule).
  private static func relativeAge(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

/// One popover row: a re-entry point, not a scoreboard line. The whole row is the action and now
/// looks like it — a persistent chevron plus a hover fill, rather than five labelled buttons on a
/// five-row surface. The second line reuses `NodeRowMeta`, the middle column's own component, so the
/// two surfaces share one implementation instead of agreeing by convention.
private struct MenuBarRow: View {
  let item: NextItem
  let facts: NodeRowFacts?
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
          Text(item.project.name).lineLimit(1)
          NodeRowMeta(facts: facts)
        }
        Spacer()
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
      }
      // Without this the `Spacer()` between the text and the chevron is dead space to hit-testing —
      // the same defect slice A's verify pass found in the detail pane's hover thumbs.
      .rowHitArea()
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 6).padding(.vertical, 4)
    .background(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .onHover { isHovering = $0 }
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
