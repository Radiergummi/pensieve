// Sources/PensieveApp/ActivityTimeline.swift
import SwiftUI
import PensieveKit

/// One day of the recall pane's timeline: the day, and its events newest first.
///
/// The bucketing is derivation and belongs in PensieveKit beside the other event queries — it is
/// here only because this pass cannot edit Kit. It does NOT restate a Kit rule: `startOfDay` appears
/// exactly once in the repository, so there is no second copy to drift from.
struct ActivityDay: Identifiable {
  let id: Date
  let events: [Event]
  var day: Date { id }

  /// Events grouped by calendar day, newest day first and newest event first within a day.
  /// Computed once per detail load (off `body`, from `DetailView`'s `.task`) rather than on every
  /// render: the pane re-renders on every ⌘F keystroke, and this was a `Dictionary(grouping:)` plus
  /// two sorts each time.
  static func bucket(_ events: [Event]) -> [ActivityDay] {
    let groups = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.occurredAt) }
    return groups.keys.sorted(by: >).map { day in
      ActivityDay(id: day, events: (groups[day] ?? []).sorted { $0.occurredAt > $1.occurredAt })
    }
  }
}

/// A GitHub-style vertical-rail timeline: events grouped by day, a colored dot per event on a rail,
/// the source icon+color, the localized source label, and the summary. No avatars (single-user).
struct ActivityTimeline: View {
  let days: [ActivityDay]
  var find: NodeFindState?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(days) { day in
        VStack(alignment: .leading, spacing: 12) {
          Text(day.day, format: .dateTime.weekday(.wide).month().day())
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
          ForEach(Array(day.events.enumerated()), id: \.element.id) { offset, event in
            TimelineRow(event: event, isLast: offset == day.events.count - 1, find: find)
          }
        }
      }
    }
  }
}

private struct TimelineRow: View {
  let event: Event
  let isLast: Bool
  var find: NodeFindState?

  var body: some View {
    let style = EventSourceStyle.style(for: event.kind)
    let color = AppearanceStyle.color(style.colorTag)
    HStack(alignment: .top, spacing: 10) {
      VStack(spacing: 0) {
        Circle().fill(color).frame(width: 8, height: 8).padding(.top, 2)
        if !isLast { Rectangle().fill(.quaternary).frame(width: 1.5).frame(maxHeight: .infinity) }
      }
      .frame(width: 8)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          sourceIcon(style).font(.caption).foregroundStyle(color)
          Text(AppearanceStyle.sourceLabel(event.kind)).metaText()
          Text(event.occurredAt, format: .dateTime.hour().minute())
            .metaText().monospacedDigit()
        }
        summaryText
      }
      Spacer()
    }
  }

  @ViewBuilder private var summaryText: some View {
    let anchor = FindAnchor.event(event.id)
    let runs = find?.runs(for: anchor, text: event.summary) ?? []
    Group {
      if runs.isEmpty {
        Text(event.summary)
      } else {
        HighlightedText(runs: runs, currentOffset: find?.currentOffset(in: anchor))
      }
    }
    .prose()
    .findSite(anchor, find)
  }

  @ViewBuilder private func sourceIcon(_ sourceStyle: SourceStyle) -> some View {
    switch AppearanceIcon.parse(sourceStyle.icon) {
    case .sfSymbol(let symbolName): Image(systemName: symbolName)
    case .emoji(let emoji):    Text(emoji)
    case nil:              Image(systemName: "circle.fill")
    }
  }
}
