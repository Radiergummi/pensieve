import Foundation
import Testing
@testable import PensieveKit

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
  // Hour 12 in the current calendar → no midnight rollover in any real timezone, so the
  // yyyy-MM-dd the builder formats (in TimeZone.current) is deterministic across machines.
  Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

private func looseEnd(_ text: String, quote: String, on occurrenceDate: Date) -> LooseEndView {
  LooseEndView(looseEnd: LooseEnd(nodeID: UUID(), sourceEventID: UUID(), text: text, quote: quote),
               occurredAt: occurrenceDate, ageDays: 0)
}

private func event(_ summary: String, on occurrenceDate: Date) -> Event {
  Event(nodeID: UUID(), sourceID: UUID(), occurredAt: occurrenceDate, kind: "git.commit",
        summary: summary, detailJSON: "{}")
}

@Test func rendersFullRecallAsExpectedMarkdown() {
  var node = Node(name: "Auth", kind: .strand, description: "OAuth + token refresh.")
  node.state = .active
  let markdown = RecallMarkdown.render(
    node: node,
    narration: "Wired up refresh-token rotation.",
    looseEnds: [looseEnd("rotate on 401", quote: "SECRET-QUOTE", on: date(2026, 7, 6))],
    events: [event("add rate limit", on: date(2026, 7, 7))],
    now: date(2026, 7, 8))

  #expect(markdown == """
  # Auth

  *Strand · Active*

  OAuth + token refresh.

  ## Last Work Done

  Wired up refresh-token rotation.

  ## Loose Ends

  - rotate on 401

  ## Recent Activity

  - 2026-07-07 — add rate limit

  ---
  _Shared from Pensieve · 2026-07-08_

  """)
}

@Test func neverEmitsVerbatimQuote() {
  let node = Node(name: "X", kind: .project)
  let markdown = RecallMarkdown.render(
    node: node, narration: nil,
    looseEnds: [looseEnd("do the thing", quote: "DISTINCTIVE-SENTINEL-QUOTE", on: date(2026, 7, 1))],
    events: [], now: date(2026, 7, 2))
  #expect(!markdown.contains("DISTINCTIVE-SENTINEL-QUOTE"))   // provenance quotes never leave via a share
  #expect(markdown.contains("- do the thing"))                // but the summary text does
}

@Test func omitsNarrationSectionWhenNil() {
  let node = Node(name: "X", kind: .project)
  let markdown = RecallMarkdown.render(node: node, narration: nil, looseEnds: [], events: [], now: date(2026, 7, 2))
  #expect(!markdown.contains("## Last Work Done"))
}

@Test func omitsNarrationSectionWhenEmptyString() {
  let node = Node(name: "X", kind: .project)
  let markdown = RecallMarkdown.render(node: node, narration: "", looseEnds: [], events: [], now: date(2026, 7, 2))
  #expect(!markdown.contains("## Last Work Done"))
}

@Test func emptyLooseEndsAndEventsShowPlaceholders() {
  let node = Node(name: "X", kind: .project)
  let markdown = RecallMarkdown.render(node: node, narration: nil, looseEnds: [], events: [], now: date(2026, 7, 2))
  #expect(markdown.contains("## Loose Ends\n\n_None open._"))
  #expect(markdown.contains("## Recent Activity\n\n_No captured activity._"))
}

/// Share/copy exports what is displayed: a loose end with a stored translation exports the
/// translation, one with none falls back to the English original — mirroring `NodeFindDocument.make`.
@Test func exportsTranslatedSummaryWhenPresentAndFallsBackWhenAbsent() {
  let node = Node(name: "X", kind: .project)
  let translated = looseEnd("rotate on 401", quote: "SECRET-QUOTE", on: date(2026, 7, 6))
  let untranslated = looseEnd("do the thing", quote: "OTHER-QUOTE", on: date(2026, 7, 6))
  let markdown = RecallMarkdown.render(
    node: node, narration: nil,
    looseEnds: [translated, untranslated], events: [], now: date(2026, 7, 8),
    translatedLooseEndText: [translated.looseEnd.id: "auf 401 zurücksetzen"])
  #expect(markdown.contains("- auf 401 zurücksetzen"))
  #expect(markdown.contains("- do the thing"))
  #expect(!markdown.contains("- rotate on 401"))
}

@Test func omitsDescriptionLineWhenEmpty() {
  let node = Node(name: "X", kind: .project)   // description defaults to ""
  let markdown = RecallMarkdown.render(node: node, narration: nil, looseEnds: [], events: [], now: date(2026, 7, 2))
  // header line is immediately followed by the meta line and then the first section — no stray blank block
  #expect(markdown.contains("# X\n\n*Project · Active*\n\n## Loose Ends"))
}
