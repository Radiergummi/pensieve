import SwiftUI
import WidgetKit
import PensieveKit

struct WhatsNextView: View {
  @Environment(\.widgetFamily) private var family
  let presentation: WidgetPresentation
  /// What the digest was filtered by ("work"/"personal"/nil) — user-chosen Focus-context data, so
  /// it renders verbatim like a project name, never through a localized lookup.
  let context: String?

  var body: some View {
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
    Text(key).font(.caption).foregroundStyle(.secondary).padding()
  }

  /// Names the active Focus context in the header on the populated render too, not just the empty
  /// state — the widget is sandboxed and cannot read the app's Focus defaults, so this label is the
  /// only way a stale WORK-only digest, listed under an unlabelled "What's Next" while Personal is
  /// active on the (closed) app, becomes visible rather than silent.
  private var header: Text {
    // `context` is user Focus-context data, not chrome — interpolated verbatim, never localized.
    if let context {
      return Text("What's Next · \(context)")
    }
    return Text("What's Next")
  }

  @ViewBuilder
  private func queue(_ items: [WidgetDigest.Item], asOf: Date?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      header.font(.caption2).foregroundStyle(.secondary)
      if items.isEmpty {
        // A valid digest with no items (e.g. an active Focus context matching no projects) is NOT
        // an empty list: that reads as a broken widget, one step from telling the user they have
        // nothing to do — the one false statement this widget must never make.
        emptyState
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
    .padding()
    .widgetURL(DeepLink.smartList(.whatsNext).url)
  }

  @ViewBuilder
  private var emptyState: some View {
    // `context` is user Focus-context data, not chrome — interpolated verbatim, never localized.
    if let context {
      Text("Nothing open in \(context)").font(.footnote).foregroundStyle(.secondary)
    } else {
      Text("Nothing open").font(.footnote).foregroundStyle(.secondary)
    }
  }
}
