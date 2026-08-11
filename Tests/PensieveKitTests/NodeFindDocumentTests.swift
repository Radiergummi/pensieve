import Foundation
import Testing
@testable import PensieveKit

private func makeNode(name: String, description: String) -> Node {
  Node(name: name, description: description)
}

private func makeLooseEndView(text: String, quote: String) -> LooseEndView {
  let looseEnd = LooseEnd(nodeID: UUID(), sourceEventID: UUID(), text: text, quote: quote)
  return LooseEndView(looseEnd: looseEnd, occurredAt: Date(), ageDays: 3)
}

private func makeEvent(summary: String) -> Event {
  Event(nodeID: UUID(), sourceID: UUID(), occurredAt: Date(), kind: "git.commit",
        summary: summary, detailJSON: "{}")
}

@Test func documentOrderFollowsOnScreenOrder() {
  let node = makeNode(name: "Pensieve", description: "a recall tool")
  let looseEnd = makeLooseEndView(text: "ship the find bar", quote: "we should ship the find bar")
  let event = makeEvent(summary: "feat: find bar")
  let document = NodeFindDocument.make(node: node, narration: "worked on find",
                                       looseEnds: [looseEnd], events: [event],
                                       showsLooseEnds: true)
  let anchors = document.units.map(\.anchor)
  #expect(anchors.first == .nodeName)
  #expect(anchors[1] == .description)
  #expect(anchors[2] == .narration)
  #expect(anchors[3] == .looseEndText(looseEnd.looseEnd.id))
  #expect(anchors.last == .event(event.id))
}

@Test func showsLooseEndsFalseOmitsEveryLooseEndUnit() {
  // The one-home rule: a childless focused strand shows its loose ends in the MIDDLE column, and
  // the detail renders no Loose Ends section at all. Indexing them would produce matches with no
  // site to scroll to.
  let looseEnd = makeLooseEndView(text: "ship the find bar", quote: "ship the find bar")
  let document = NodeFindDocument.make(node: makeNode(name: "Pensieve", description: ""),
                                       narration: nil, looseEnds: [looseEnd], events: [],
                                       showsLooseEnds: false)
  #expect(document.units.allSatisfy { unit in
    if case .looseEndText = unit.anchor { return false }
    if case .looseEndQuote = unit.anchor { return false }
    if case .transcriptSegment = unit.anchor { return false }
    return true
  })
  #expect(document.unresolvedLooseEndIDs.isEmpty)
}

@Test func nilNarrationContributesNoUnit() {
  let document = NodeFindDocument.make(node: makeNode(name: "Pensieve", description: ""),
                                       narration: nil, looseEnds: [], events: [],
                                       showsLooseEnds: true)
  #expect(!document.units.contains { $0.anchor == .narration })
}

@Test func matchesAreOrdinalNumberedInDocumentOrder() {
  let node = makeNode(name: "sync", description: "the sync store")
  let document = NodeFindDocument.make(node: node, narration: nil, looseEnds: [], events: [],
                                       showsLooseEnds: true)
  let matches = document.matches(query: "sync")
  #expect(matches.count == 2)
  #expect(matches[0].anchor == .nodeName)
  #expect(matches[0].ordinal == 1)
  #expect(matches[1].anchor == .description)
  #expect(matches[1].ordinal == 2)
  #expect(matches[1].offset == 4)      // "the sync store"
  #expect(matches[1].length == 4)
}

@Test func fillPlacesProvenanceUnitsInSlotOrderNotArrivalOrder() {
  let first = makeLooseEndView(text: "first end", quote: "first end")
  let second = makeLooseEndView(text: "second end", quote: "second end")
  var document = NodeFindDocument.make(node: makeNode(name: "n", description: ""), narration: nil,
                                       looseEnds: [first, second], events: [], showsLooseEnds: true)
  #expect(document.unresolvedLooseEndIDs == [first.looseEnd.id, second.looseEnd.id])
  // Fill the SECOND one first — arrival order is file order, not document order.
  document.fill(looseEndID: second.looseEnd.id,
                units: [FindUnit(anchor: .transcriptSegment(looseEndID: second.looseEnd.id,
                                                            messageIndex: 7, segment: 0),
                                 text: "second transcript")])
  document.fill(looseEndID: first.looseEnd.id,
                units: [FindUnit(anchor: .transcriptSegment(looseEndID: first.looseEnd.id,
                                                            messageIndex: 7, segment: 0),
                                 text: "first transcript")])
  let texts = document.units.map(\.text)
  #expect(texts.firstIndex(of: "first transcript")! < texts.firstIndex(of: "second transcript")!)
  #expect(document.unresolvedLooseEndIDs.isEmpty)
}

@Test func aFilledSlotHoldsEitherTranscriptUnitsOrTheQuoteNeverBoth() {
  // The quote is rendered ONLY in the transcript-unavailable fallback (LooseEndRow.swift:105), and
  // it is by construction a substring of the cited message — indexing both double-counts the same
  // text AND points one match at a site that does not exist.
  let looseEnd = makeLooseEndView(text: "ship it", quote: "we should ship it")
  var document = NodeFindDocument.make(node: makeNode(name: "n", description: ""), narration: nil,
                                       looseEnds: [looseEnd], events: [], showsLooseEnds: true)
  document.fillWithQuoteFallback(looseEndID: looseEnd.looseEnd.id, quote: looseEnd.looseEnd.quote)
  let anchors = document.units.map(\.anchor)
  #expect(anchors.contains(.looseEndQuote(looseEnd.looseEnd.id)))
  #expect(!anchors.contains { if case .transcriptSegment = $0 { return true } else { return false } })
}

@Test func unfilledSlotsContributeNoUnitsYet() {
  let looseEnd = makeLooseEndView(text: "ship it", quote: "we should ship it")
  let document = NodeFindDocument.make(node: makeNode(name: "n", description: ""), narration: nil,
                                       looseEnds: [looseEnd], events: [], showsLooseEnds: true)
  #expect(document.matches(query: "we should").isEmpty)   // quote not indexed until the slot resolves
  // The node-name unit is always present; only the loose end's provenance slot is pending.
  #expect(document.units.map(\.anchor) == [.nodeName, .looseEndText(looseEnd.looseEnd.id)])
}

@Test func textForAnchorReturnsTheUnitBody() {
  let node = makeNode(name: "Pensieve", description: "a recall tool")
  let document = NodeFindDocument.make(node: node, narration: nil, looseEnds: [], events: [],
                                       showsLooseEnds: true)
  #expect(document.text(for: .description) == "a recall tool")
  #expect(document.text(for: .narration) == nil)
}

@Test func fillWithQuoteFallbackOnEmptyQuoteContributesNoUnit() {
  // Guards the isEmpty branch in fillWithQuoteFallback: an empty stored quote must resolve the
  // slot to zero units, not a unit holding empty text (which would still show up as "resolved" but
  // add a phantom findable anchor with nothing in it).
  let looseEnd = makeLooseEndView(text: "ship it", quote: "")
  var document = NodeFindDocument.make(node: makeNode(name: "n", description: ""), narration: nil,
                                       looseEnds: [looseEnd], events: [], showsLooseEnds: true)
  document.fillWithQuoteFallback(looseEndID: looseEnd.looseEnd.id, quote: "")
  #expect(document.unresolvedLooseEndIDs.isEmpty)
  #expect(!document.units.contains { $0.anchor == .looseEndQuote(looseEnd.looseEnd.id) })
}

@Test func fillingAnUnknownLooseEndIDIsANoOp() {
  // resolve() walks slots looking for a matching provenance slot; if none matches it must return
  // without touching state — asserts the loop's "no match found" path rather than only its happy
  // path.
  let looseEnd = makeLooseEndView(text: "ship it", quote: "we should ship it")
  var document = NodeFindDocument.make(node: makeNode(name: "n", description: ""), narration: nil,
                                       looseEnds: [looseEnd], events: [], showsLooseEnds: true)
  document.fill(looseEndID: UUID(),
                units: [FindUnit(anchor: .transcriptSegment(looseEndID: UUID(), messageIndex: 0,
                                                            segment: 0), text: "unrelated")])
  #expect(document.unresolvedLooseEndIDs == [looseEnd.looseEnd.id])
  #expect(document.units.map(\.anchor) == [.nodeName, .looseEndText(looseEnd.looseEnd.id)])
}
