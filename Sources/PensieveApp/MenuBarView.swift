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
  /// Colour for the POPOVER orb only. The menu-bar glyph deliberately keeps no tint — it is a
  /// template image, which is what lets macOS invert it for the wallpaper behind it and for Reduce
  /// Transparency. Semantic system roles, like `SmartListKind.color` already uses.
  var tint: Color {
    switch self {
    case .active: return .green
    case .idle: return .secondary
    case .notSetUp: return .orange
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
      // The orb doubles as the refresh indicator — one moving part in a 320pt row, not two. The fixed
      // frame keeps the status text from shifting when the spinner (wider than the glyph) swaps in.
      ZStack {
        if model.isRefreshing {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: model.snapshot.status.glyph)
            .foregroundStyle(model.snapshot.status.tint)
        }
      }
      .frame(width: 16, height: 16)
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
        MenuBarRow(item: item) {
          applyDeepLink(.node(item.project.id), model: model, openWindow: openWindow)
        }
      }
    }
  }

  @ViewBuilder private var footer: some View {
    HStack(spacing: 8) {
      // Leading primary, hugging its label. It used to fill the row, and the comment here claimed the
      // fill was what stopped German truncating to `Pensieve öf…`. It was not: the fix was dropping
      // from three buttons to one (backlog.md, 2026-08-12 verify pass). At a 320pt popover that leaves
      // roughly 180pt of slack, which the Spacer below absorbs before the button ever gives up width.
      // `.borderedProminent` rather than a glass style — the `.window` popover surface is already
      // system glass, so a glass button on it would be glass on glass. It also picks up the accent.
      Button("Open Pensieve") {
        applyDeepLink(.briefing, model: model, openWindow: openWindow)
      }
      .buttonStyle(.borderedProminent)

      Spacer(minLength: 8)

      // Refresh lives in the ROW, not in the menu below. Clicking a menu item dismisses the popover,
      // so a refresh started from there finished somewhere the user could not watch — which is what
      // made a working command read as a no-op. Here it stays on screen and the orb above spins.
      Button {
        Task { await model.refreshNow() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
      .disabled(model.isRefreshing)
      .help("Refresh")
      .accessibilityLabel("Refresh")

      // `.menuStyle(.button)` + `.buttonStyle(.bordered)` rather than `.borderlessButton`: the
      // borderless style draws no hover or pressed state at all, so the control gave no sign it was
      // a control. The bordered pair gets hover, press and a focus ring from the system.
      Menu {
        SettingsLink { Text("Settings…") }
        Button("Quit") { NSApplication.shared.terminate(nil) }
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.button)
      .buttonStyle(.bordered)
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

  /// The SAME Foundation relative style the rows below already use (`NodeMeta.recency`), so the
  /// popover carries one date vocabulary instead of two. It replaced a `RelativeDateTimeFormatter`
  /// with `.abbreviated` units, which rendered German as "erfasst vor 2 m" directly above rows
  /// reading "vor 3 Tagen". Being a format style rather than a formatter object, there is also no
  /// shared-mutable-static question to answer.
  private static func relativeAge(_ date: Date) -> String {
    date.formatted(.relative(presentation: .named))
  }
}

/// One popover row: a re-entry point, not a scoreboard line — the whole row is the action, and the
/// chevron plus hover fill say so. The second line reuses `NodeRowMeta`, the middle column's own
/// component, so the two surfaces share one implementation instead of agreeing by convention.
///
/// The facts come from the `NextItem` itself. `NextQueries.ranked` already reads the latest event to
/// derive `daysDormant` and now keeps its `Date`, so the row needs nothing the list did not already
/// fetch — which is what lets `refreshGlance()` skip the two whole-database aggregates it used to run
/// to rebuild `nodeRowFacts` for this one line.
private struct MenuBarRow: View {
  let item: NextItem
  let action: () -> Void

  private var facts: NodeRowFacts {
    NodeRowFacts(lastActivityAt: item.lastActivityAt, openLooseEnds: item.openLooseEnds)
  }
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
          Text(item.project.name).lineLimit(1)
          NodeRowMeta(facts: facts)
        }
        Spacer()
        // NOT `chevron.right`, which is the disclosure idiom — it promises a level below this one,
        // inside this surface. The row leaves for the main window instead, so it takes the glyph
        // macOS uses for exactly that. A drill-in level was specced and dropped: it would have shown
        // 5 of the largest node's 299 open ends with no resolve verbs, duplicating the Loose Ends
        // bucket, and decaying into a copy of Recent Activity as the queue is burned down.
        Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.tertiary)
      }
      // The padding stays inside the label (above this call), or the hover fill paints a wider
      // rectangle than the button actually hit-tests.
      .padding(.horizontal, 6).padding(.vertical, 4)
      .rowHitArea()
    }
    .buttonStyle(.plain)
    .background(.quaternary.opacity(isHovering ? 1 : 0),
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
