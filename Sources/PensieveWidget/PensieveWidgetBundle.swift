import SwiftUI
import WidgetKit

@main
struct PensieveWidgetBundle: WidgetBundle {
  var body: some Widget { WhatsNextWidget() }
}

struct ProbeEntry: TimelineEntry {
  let date: Date
  let resolved: String
}

struct ProbeProvider: TimelineProvider {
  func placeholder(in context: Context) -> ProbeEntry { ProbeEntry(date: Date(), resolved: "…") }

  func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
    completion(entry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
    completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(900))))
  }

  /// TEMPORARY: proves whether the sandbox honours the App Group entitlement.
  private func entry() -> ProbeEntry {
    let group = "TH593VRB6W.me.mazetti.pensieve"
    let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    return ProbeEntry(date: Date(), resolved: url?.path ?? "NIL — entitlement not honoured")
  }
}

struct WhatsNextWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "WhatsNext", provider: ProbeProvider()) { entry in
      Text(entry.resolved).font(.caption2).padding()
    }
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
