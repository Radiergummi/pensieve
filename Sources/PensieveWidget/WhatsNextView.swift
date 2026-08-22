import SwiftUI
import WidgetKit
import PensieveKit

struct WhatsNextView: View {
  @Environment(\.widgetFamily) private var family
  let presentation: WidgetPresentation
  /// What the digest was filtered by ("work"/"personal"/nil). Chrome, not captured content — the app
  /// writes these values through a localized picker, so they are named, not echoed.
  let context: String?

  /// `containerBackground(for: .widget)` is MANDATORY since macOS 14 — a widget that does not adopt
  /// it renders WidgetKit's "Please adopt containerBackground API" placeholder INSTEAD of its view,
  /// in the gallery and on the desktop, with no build warning to say so. It also takes over the
  /// insets, which is why nothing below pads itself.
  ///
  /// The tap target belongs to EVERY state, not just the populated queue: "Open Pensieve to get
  /// started" that does nothing when clicked is worse than no instruction at all, and a widget with
  /// no `widgetURL` and no `Link` in the tapped area is inert on macOS with nothing to say so.
  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .containerBackground(.fill.tertiary, for: .widget)
      .widgetURL(DeepLink.smartList(.whatsNext).url)
  }

  @ViewBuilder
  private var content: some View {
    switch presentation {
    case .noData:
      // NOT an empty list: an empty What's Next reads as "nothing to do", which is the one thing
      // this widget must never imply when it simply has no data.
      message("Open Pensieve to get started")
    case .unsupportedSchema:
      message("Update Pensieve")
    case .fresh(let items):
      queue(items, asOf: nil)
    case .stale(let items, let generatedAt):
      queue(items, asOf: generatedAt)
    }
  }

  private func message(_ key: LocalizedStringKey) -> some View {
    Text(key).font(.caption).foregroundStyle(.secondary)
  }

  /// Names the active Focus context in the header on the populated render too, not just the empty
  /// state — the widget is sandboxed and cannot read the app's Focus defaults, so this label is the
  /// only way a stale WORK-only digest, listed under an unlabelled "What's Next" while Personal is
  /// active on the (closed) app, becomes visible rather than silent.
  private var header: Text {
    if let context {
      return Text("What's Next · \(localizedContext(context))")
    }
    return Text("What's Next")
  }

  /// Localized out of THIS bundle: an appex cannot reach the app's catalog, which is why the shared
  /// rule in `NodeContext.displayKey` hands back a key rather than a translation.
  private func localizedContext(_ context: String) -> String {
    guard let key = NodeContext.displayKey(context) else { return context }
    return String(localized: String.LocalizationValue(key))
  }

  @ViewBuilder
  private func queue(_ items: [WidgetDigest.Item], asOf: Date?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      header.font(.caption2).foregroundStyle(.secondary)
      if items.isEmpty {
        // A valid digest with no items (e.g. an active Focus context matching no projects) is NOT
        // an empty list: that reads as a broken widget, one step from telling the user they have
        // nothing to do — the one false statement this widget must never make. The header above
        // already names the context this is empty *within*, so this line does not repeat it.
        Text("Nothing open").font(.footnote).foregroundStyle(.secondary)
      } else {
        // Project names are captured content — never localized.
        ForEach(items.prefix(family == .systemSmall ? 1 : 3), id: \.nodeID) { item in
          Link(destination: DeepLink.node(item.nodeID).url) {
            VStack(alignment: .leading, spacing: 1) {
              Text(item.name).font(.footnote.weight(.medium)).lineLimit(1)
              Text("\(item.openLooseEnds) open").font(.caption2).foregroundStyle(.secondary)
            }
          }
        }
      }
      if let asOf {
        Spacer(minLength: 0)
        Text("as of \(asOf.formatted(date: .omitted, time: .shortened))")
          .font(.caption2).foregroundStyle(.tertiary)
      }
    }
  }
}
