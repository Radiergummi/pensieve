import Foundation
import Testing
@testable import PensieveKit

private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
  // Hour 12 in the current calendar → no midnight rollover in any real timezone, so the
  // yyyy-MM-dd the builder formats (in TimeZone.current) is deterministic across machines.
  Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

private func looseEnd(_ text: String, quote: String, on d: Date) -> LooseEndView {
  LooseEndView(looseEnd: LooseEnd(nodeID: UUID(), sourceEventID: UUID(), text: text, quote: quote),
               occurredAt: d, ageDays: 0)
}

private func event(_ summary: String, on d: Date) -> Event {
  Event(nodeID: UUID(), sourceID: UUID(), occurredAt: d, kind: "git.commit",
        summary: summary, detailJSON: "{}")
}

@Test func rendersFullRecallAsExpectedMarkdown() {
  var node = Node(name: "Auth", kind: "strand", description: "OAuth + token refresh.")
  node.state = "active"
  let md = RecallMarkdown.render(
    node: node,
    narration: "Wired up refresh-token rotation.",
    looseEnds: [looseEnd("rotate on 401", quote: "SECRET-QUOTE", on: date(2026, 7, 6))],
    events: [event("add rate limit", on: date(2026, 7, 7))],
    now: date(2026, 7, 8))

  #expect(md == """
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
  let node = Node(name: "X", kind: "project")
  let md = RecallMarkdown.render(
    node: node, narration: nil,
    looseEnds: [looseEnd("do the thing", quote: "DISTINCTIVE-SENTINEL-QUOTE", on: date(2026, 7, 1))],
    events: [], now: date(2026, 7, 2))
  #expect(!md.contains("DISTINCTIVE-SENTINEL-QUOTE"))   // provenance quotes never leave via a share
  #expect(md.contains("- do the thing"))                // but the summary text does
}

@Test func omitsNarrationSectionWhenNil() {
  let node = Node(name: "X", kind: "project")
  let md = RecallMarkdown.render(node: node, narration: nil, looseEnds: [], events: [], now: date(2026, 7, 2))
  #expect(!md.contains("## Last Work Done"))
}

@Test func omitsNarrationSectionWhenEmptyString() {
  let node = Node(name: "X", kind: "project")
  let md = RecallMarkdown.render(node: node, narration: "", looseEnds: [], events: [], now: date(2026, 7, 2))
  #expect(!md.contains("## Last Work Done"))
}

@Test func emptyLooseEndsAndEventsShowPlaceholders() {
  let node = Node(name: "X", kind: "project")
  let md = RecallMarkdown.render(node: node, narration: nil, looseEnds: [], events: [], now: date(2026, 7, 2))
  #expect(md.contains("## Loose Ends\n\n_None open._"))
  #expect(md.contains("## Recent Activity\n\n_No captured activity._"))
}

@Test func omitsDescriptionLineWhenEmpty() {
  let node = Node(name: "X", kind: "project")   // description defaults to ""
  let md = RecallMarkdown.render(node: node, narration: nil, looseEnds: [], events: [], now: date(2026, 7, 2))
  // header line is immediately followed by the meta line and then the first section — no stray blank block
  #expect(md.contains("# X\n\n*Project · Active*\n\n## Loose Ends"))
}
