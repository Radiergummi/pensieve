import Testing
import Foundation
@testable import PensieveKit

private func makeItem(_ name: String, open: Int = 1) -> WidgetDigest.Item {
  WidgetDigest.Item(nodeID: UUID(), name: name, openLooseEnds: open)
}

/// The digest crosses a process boundary, so a round-trip is the contract.
@Test func digestRoundTripsThroughJSON() throws {
  let digest = WidgetDigest(schemaVersion: WidgetDigest.currentSchemaVersion,
                            generatedAt: Date(timeIntervalSince1970: 2_000_000),
                            context: NodeContext.work, items: [makeItem("Pensieve")])
  let decoded = try JSONDecoder().decode(WidgetDigest.self, from: try JSONEncoder().encode(digest))
  #expect(decoded == digest)
}

/// A newer app must be able to change the format without an older widget rendering nonsense.
@Test func aFutureSchemaIsRefusedRatherThanRendered() {
  let digest = WidgetDigest(schemaVersion: WidgetDigest.currentSchemaVersion + 1,
                            generatedAt: Date(), context: nil, items: [makeItem("Pensieve")])
  #expect(WidgetDigest.presentation(for: digest, now: Date()) == .unsupportedSchema)
}

/// An absent file must NOT render as an empty queue: "nothing to do" is the one lie this widget
/// must never tell, and an empty What's Next reads exactly that way.
@Test func anAbsentDigestIsNoDataNotAnEmptyQueue() {
  #expect(WidgetDigest.presentation(for: nil, now: Date()) == .noData)
}

/// Background sync was dead for five days in 2026-08 and nothing surfaced it. Stale data still
/// renders — but labelled — so an outage is visible on the desktop instead of silent.
@Test func stalenessFlipsExactlyAtTheThreshold() {
  let now = Date(timeIntervalSince1970: 10_000_000)
  let items = [makeItem("Pensieve")]

  let justFresh = WidgetDigest(schemaVersion: WidgetDigest.currentSchemaVersion,
                               generatedAt: now.addingTimeInterval(-WidgetDigest.stalenessThreshold + 1),
                               context: nil, items: items)
  #expect(WidgetDigest.presentation(for: justFresh, now: now) == .fresh(items))

  let justStale = WidgetDigest(schemaVersion: WidgetDigest.currentSchemaVersion,
                               generatedAt: now.addingTimeInterval(-WidgetDigest.stalenessThreshold - 1),
                               context: nil, items: items)
  #expect(WidgetDigest.presentation(for: justStale, now: now)
          == .stale(items, generatedAt: justStale.generatedAt))
}

/// An unreadable or corrupt file degrades to noData rather than throwing into a timeline provider.
@Test func unreadableFileReadsAsNil() throws {
  let url = tempURL("widget-digest", ext: "json")
  try Data("not json".utf8).write(to: url)
  #expect(WidgetDigest.read(from: url) == nil)
}

/// An absent file is the widget's common case — the app just hasn't published yet, or ever. Its
/// only crash guard is "never throws into a timeline provider," so this is the case that matters most.
@Test func absentFileReadsAsNil() {
  let url = tempURL("widget-digest-absent", ext: "json")
  #expect(WidgetDigest.read(from: url) == nil)
}
