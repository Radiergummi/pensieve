import SwiftUI
import WidgetKit
import PensieveKit

@main
struct PensieveWidgetBundle: WidgetBundle {
  var body: some Widget { WhatsNextWidget() }
}

struct WhatsNextEntry: TimelineEntry {
  let date: Date
  let presentation: WidgetPresentation
  /// What the digest was filtered by ("work"/"personal"/nil), read from the same decoded digest as
  /// `presentation` — `WidgetDigest.presentation(for:now:)` does not surface it on its own.
  let context: String?
}

struct WhatsNextProvider: TimelineProvider {
  func placeholder(in context: Context) -> WhatsNextEntry {
    WhatsNextEntry(date: Date(), presentation: .noData, context: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (WhatsNextEntry) -> Void) {
    completion(entry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<WhatsNextEntry>) -> Void) {
    // WidgetKit budgets reloads regardless; the app calls reloadAllTimelines() for the moments
    // that actually matter (a Focus switch, a store refresh).
    completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(15 * 60))))
  }

  /// All the judgement lives in PensieveKit, where tests can reach it. This is a lookup.
  private func entry() -> WhatsNextEntry {
    let now = Date()
    let digest = WidgetDigest.read(from: PensievePaths.widgetDigestURL())
    return WhatsNextEntry(date: now,
                          presentation: WidgetDigest.presentation(for: digest, now: now),
                          context: digest?.context)
  }
}

struct WhatsNextWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "WhatsNext", provider: WhatsNextProvider()) { entry in
      WhatsNextView(presentation: entry.presentation, context: entry.context)
    }
    .configurationDisplayName("What's Next")
    .description("Which projects to pick up.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
