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
    completion(entry(WidgetDigest.read(from: PensievePaths.widgetDigestURL()), at: Date()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<WhatsNextEntry>) -> Void) {
    // WidgetKit budgets reloads regardless; the app calls reloadAllTimelines() for the moments
    // that actually matter (a Focus switch, a store refresh).
    let now = Date()
    let digest = WidgetDigest.read(from: PensievePaths.widgetDigestURL())
    var entries = [entry(digest, at: now)]
    // Cross into "as of HH:MM" ON the staleness threshold rather than at whatever reload happens to
    // come next: with only a `now` entry, a 15-minute reload cadence would present a 35-minute-old
    // digest as current, which is half the honesty the 20-minute threshold was chosen for.
    if let generatedAt = digest?.generatedAt {
      let becomesStale = generatedAt.addingTimeInterval(WidgetDigest.stalenessThreshold + 1)
      if becomesStale > now { entries.append(entry(digest, at: becomesStale)) }
    }
    logTimeline(digest, presentation: entries[0].presentation, now: now)
    completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
  }

  /// A failed read renders "Open Pensieve to get started", which is indistinguishable from a widget
  /// that is merely empty — and an appex is invisible from the outside, so the two states cost real
  /// debugging time once already. Counts and timestamps only: node names are captured content and
  /// never go to the log.
  ///
  /// `digest=` is what the log line was still missing. `WidgetDigest.read` collapses "no file yet"
  /// and "a file that would not decode" into the same nil, and both render `.noData`, so the log
  /// could not tell the honest pre-first-publish state from a real bug. A torn write is not a third
  /// possibility — `WidgetDigestPublisher.publish` writes `.atomic` — so a file that exists and
  /// still decodes to nil means the format disagrees, which is worth seeing.
  private func logTimeline(_ digest: WidgetDigest?, presentation: WidgetPresentation, now: Date) {
    let state: String
    var itemCount = 0
    switch presentation {
    case .noData: state = "noData"
    case .unsupportedSchema: state = "unsupportedSchema"
    case .fresh(let items): state = "fresh"; itemCount = items.count
    case .stale(let items, _): state = "stale"; itemCount = items.count
    }
    let digestURL = PensievePaths.widgetDigestURL()
    let digestState: String
    if digest != nil {
      digestState = "decoded"
    } else {
      digestState = FileManager.default.fileExists(atPath: digestURL.path) ? "undecodable" : "absent"
    }
    let ageInSeconds = digest.map { Int(now.timeIntervalSince($0.generatedAt)) } ?? -1
    WidgetLog.widget.info("""
      timeline: \(state, privacy: .public) digest=\(digestState, privacy: .public) \
      items=\(itemCount, privacy: .public) age=\(ageInSeconds, privacy: .public)s
      """)
  }

  /// All the judgement lives in PensieveKit, where tests can reach it. This is a lookup. `date` is
  /// also the `now` the presentation is judged against — that is what lets a FUTURE entry be built
  /// for the moment this same digest turns stale.
  private func entry(_ digest: WidgetDigest?, at date: Date) -> WhatsNextEntry {
    WhatsNextEntry(date: date,
                   presentation: WidgetDigest.presentation(for: digest, now: date),
                   context: digest?.context)
  }
}

struct WhatsNextWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "WhatsNext", provider: WhatsNextProvider()) { entry in
      WhatsNextView(presentation: entry.presentation, context: entry.context)
    }
    // These two are gallery METADATA, resolved outside this process — so unlike every `Text` in
    // `WhatsNextView` they do NOT default to this bundle, and an unpinned lookup lands in
    // Pensieve.app's catalog. That failed silently and asymmetrically: the app happens to carry
    // "What's Next" (its smart-list name), so the title came out German while the description — which
    // exists ONLY here — fell back to English. `bundle:` is what pins both to this appex.
    .configurationDisplayName(LocalizedStringResource("What's Next", bundle: .widget))
    .description(LocalizedStringResource("Which projects to pick up.", bundle: .widget))
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

/// Anchors a `LocalizedStringResource` to the widget extension's own bundle. `.forClass` needs a
/// class to point at and the widget target has none, so this empty one exists purely as the anchor.
private final class WidgetBundleAnchor {}

extension LocalizedStringResource.BundleDescription {
  static let widget = LocalizedStringResource.BundleDescription.forClass(WidgetBundleAnchor.self)
}
