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

  /// The keyboard cursor over the What's Next rows. Nil when nothing is focused — including the
  /// legitimate case where there are no rows at all.
  @FocusState private var focusedRow: UUID?

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
    // Arrows go through `.onMoveCommand`, NOT `.onKeyPress`. This was measured, after shipping the
    // wrong one: a trace showed the key-set handler receiving `\r` and never once an arrow, because
    // arrow keys are consumed as MOVE COMMANDS before `onKeyPress` sees them. `.onExitCommand` firing
    // in the same trace is what proved command-style propagation reaches this container at all, and
    // therefore that `.onMoveCommand` would work where `.onKeyPress` could not.
    //
    // Still arrows rather than Tab as the designed route: Full Keyboard Access is off by default. Tab
    // happens to work here anyway (the rows are `@FocusState` targets), which is a bonus, not the plan.
    .onMoveCommand { direction in
      switch direction {
      case .up: moveFocus(by: -1)
      case .down: moveFocus(by: 1)
      default: break   // left/right have no meaning in a single column
      }
    }
    // Return stays on `onKeyPress`, where the trace confirms it does arrive. The modifier guard is
    // load-bearing: the per-key overload cannot see modifiers, so without it ⌘↩ would open the
    // focused node here AND the briefing via the footer's shortcut.
    .onKeyPress(keys: [.return]) { press in
      press.modifiers.isEmpty ? activateFocusedRow() : .ignored
    }
    // Esc reaches this view (measured); it simply had no implementation before.
    .onExitCommand { dismissMenuBarPopover() }
    .task {
      model.refreshGlance()   // refresh on open; the always-mounted label is kept live between opens by the liveness watches
      focusedRow = rows.first?.project.id   // nil when the queue is empty — no row to focus, and that is fine
    }
  }

  /// The rows actually rendered, and the single source for both the view and the key handlers — a
  /// second `prefix` call somewhere else is how the cursor would come to address a row nobody sees.
  private var rows: [NextItem] { Array(model.lists.whatsNext.prefix(Self.maxRows)) }

  /// Clamped, not wrapping: with five rows, wrap-around costs more surprise than it saves keystrokes.
  /// Returns nothing — `.onMoveCommand`'s closure is not result-carrying, unlike `.onKeyPress`'s.
  private func moveFocus(by offset: Int) {
    let ids = rows.map(\.project.id)
    guard !ids.isEmpty else { return }
    guard let current = focusedRow, let index = ids.firstIndex(of: current) else {
      focusedRow = ids.first
      return
    }
    focusedRow = ids[min(max(index + offset, 0), ids.count - 1)]
  }

  private func activateFocusedRow() -> KeyPress.Result {
    guard let focusedRow else { return .ignored }
    applyDeepLink(.node(focusedRow), model: model, openWindow: openWindow)
    return .handled
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
    if rows.isEmpty {
      Text("Nothing queued").font(.callout).foregroundStyle(.secondary)
    } else {
      ForEach(rows, id: \.project.id) { item in
        MenuBarRow(item: item, isFocused: focusedRow == item.project.id) {
          applyDeepLink(.node(item.project.id), model: model, openWindow: openWindow)
        }
        .focused($focusedRow, equals: item.project.id)
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
      //
      // The footer is reached by SHORTCUT, not by tab traversal. Arrows are bound to the row cursor
      // above, and Tab does not reach a Button unless Full Keyboard Access is on — which it is not by
      // default. Without these three, a keyboard user could move the cursor and open a node and still
      // have no route to any footer action.
      Button("Open Pensieve") {
        applyDeepLink(.briefing, model: model, openWindow: openWindow)
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.return, modifiers: .command)

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
      .keyboardShortcut("r", modifiers: .command)
      .disabled(model.isRefreshing)
      .help("Refresh")
      .accessibilityLabel("Refresh")

      // `.menuStyle(.button)` + `.buttonStyle(.bordered)` rather than `.borderlessButton`: the
      // borderless style draws no hover or pressed state at all, so the control gave no sign it was
      // a control. The bordered pair gets hover, press and a focus ring from the system.
      Menu {
        SettingsLink { Text("Settings…") }
          .keyboardShortcut(",", modifiers: .command)
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
  /// Whether the keyboard cursor is on this row. Passed in rather than read from a local
  /// `@FocusState`, because the arrow handlers live on the container and the row must render the
  /// same state they move.
  let isFocused: Bool
  let action: () -> Void

  private var facts: NodeRowFacts {
    NodeRowFacts(lastActivityAt: item.lastActivityAt, openLooseEnds: item.openLooseEnds)
  }
  @State private var isHovering = false

  /// The two-line layout reads to VoiceOver as two unrelated fragments — a bare name, then a
  /// detached "vor 3 Tagen · 288 offen". One label keeps the row a single utterance.
  ///
  /// Comma-joined rather than `NodeMeta.separator`: "·" is punctuation for the eye, and VoiceOver
  /// reads it aloud as "middle dot". `verbatim` because every component is already localized —
  /// re-localizing an assembled sentence would look for a key that cannot exist.
  private var spokenLabel: Text {
    let parts = [item.project.name,
                 NodeMeta.recencyLabel(facts.lastActivityAt),
                 NodeMeta.openCount(facts.openLooseEnds)]
    return Text(verbatim: parts.joined(separator: ", "))
  }

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
    // Focus reuses the hover fill rather than the system focus ring, and `.focusEffectDisabled()`
    // is what makes that a replacement instead of an addition — without it the row drew BOTH, which
    // read as a permanent stray outline on the first row (the popover focuses it on open so Return
    // works without arrowing first). The fill is the affordance this row already uses for "this one";
    // focus is drawn stronger than hover so the pointer and the cursor stay distinguishable on
    // different rows.
    .focusEffectDisabled()
    .background(.quaternary.opacity(isFocused ? 1 : (isHovering ? 0.6 : 0)),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .onHover { isHovering = $0 }
    // The two-line layout reads to VoiceOver as two unrelated fragments — a bare name, then a
    // detached "vor 3 Tagen · 288 offen". One label keeps the row a single utterance.
    .accessibilityElement(children: .combine)
    .accessibilityLabel(spokenLabel)
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
