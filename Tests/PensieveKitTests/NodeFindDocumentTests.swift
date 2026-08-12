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
  // The recap sits AFTER the loose ends on screen (cited content first, best-effort prose last), so
  // it sits after them here too — ⌘G walks this order.
  #expect(anchors[2] == .looseEndText(looseEnd.looseEnd.id))
  #expect(anchors[3] == .narration)
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

@Test func transcriptUnitsCarryMessageIndexAndSegmentOrdinal() {
  let looseEndID = UUID()
  let messages = [
    ProvenanceMessage(index: 4, role: "user", text: "fix the sync gap", isCited: true,
                      isUserPrompt: true),
    ProvenanceMessage(index: 5, role: "assistant", text: "on it", isCited: false,
                      isUserPrompt: false)
  ]
  let loaded = LoadedProvenance(
    context: ProvenanceContext(looseEnd: makeLooseEndView(text: "t", quote: "q").looseEnd,
                               sourceEvent: makeEvent(summary: "s"), messages: messages,
                               transcriptAvailable: true),
    segments: [[.markdown("fix the sync gap")], [.markdown("on it")]])
  let units = NodeFindDocument.units(from: loaded, looseEndID: looseEndID)
  #expect(units.count == 2)
  #expect(units[0].anchor == .transcriptSegment(looseEndID: looseEndID, messageIndex: 4, segment: 0))
  #expect(units[0].text == "fix the sync gap")
  #expect(units[1].anchor == .transcriptSegment(looseEndID: looseEndID, messageIndex: 5, segment: 0))
}

@Test func segmentsWithNoFindableTextContributeNoUnit() {
  let looseEndID = UUID()
  let messages = [ProvenanceMessage(index: 1, role: "user", text: "x", isCited: true,
                                    isUserPrompt: true)]
  let loaded = LoadedProvenance(
    context: ProvenanceContext(looseEnd: makeLooseEndView(text: "t", quote: "q").looseEnd,
                               sourceEvent: makeEvent(summary: "s"), messages: messages,
                               transcriptAvailable: true),
    segments: [[.harness(HarnessBlock(kind: .interrupted, raw: "[Request interrupted")),
                .markdown("real prose")]])
  let units = NodeFindDocument.units(from: loaded, looseEndID: looseEndID)
  #expect(units.count == 1)
  // Segment ORDINAL is the position in the rendered array — 1, not 0 — because the view enumerates
  // the same array by offset. Renumbering here would scroll to the wrong segment.
  #expect(units[0].anchor == .transcriptSegment(looseEndID: looseEndID, messageIndex: 1, segment: 1))
}

@Test func anUnavailableTranscriptYieldsNoUnitsSoTheCallerFallsBackToTheQuote() {
  let loaded = LoadedProvenance(
    context: ProvenanceContext(looseEnd: makeLooseEndView(text: "t", quote: "q").looseEnd,
                               sourceEvent: makeEvent(summary: "s"), messages: [],
                               transcriptAvailable: false),
    segments: [])
  #expect(NodeFindDocument.units(from: loaded, looseEndID: UUID()).isEmpty)
}

@Test func translatedLooseEndTextIsIndexedInsteadOfTheEnglish() {
  // The find document must index what is actually ON SCREEN. When a loose end's summary has been
  // translated on demand, the document has to hold the German text — else ⌘F highlights nothing (a
  // query for the German phrase) or the wrong span (a query for the English original, which is no
  // longer rendered).
  let looseEnd = makeLooseEndView(text: "ship the find bar", quote: "we should ship the find bar")
  let document = NodeFindDocument.make(node: makeNode(name: "n", description: ""), narration: nil,
                                       looseEnds: [looseEnd], events: [], showsLooseEnds: true,
                                       translatedLooseEndText: [looseEnd.looseEnd.id: "die Suchleiste versenden"])
  #expect(document.text(for: .looseEndText(looseEnd.looseEnd.id)) == "die Suchleiste versenden")
  #expect(document.matches(query: "Suchleiste").count == 1)
  #expect(document.matches(query: "ship").isEmpty)
}

@Test func absentTranslatedEntryFallsBackToTheEnglishText() {
  let looseEnd = makeLooseEndView(text: "ship the find bar", quote: "we should ship the find bar")
  // No entry for this loose end's id — the default empty map, and a map with unrelated entries,
  // must both fall back to the loose end's own English text.
  let document = NodeFindDocument.make(node: makeNode(name: "n", description: ""), narration: nil,
                                       looseEnds: [looseEnd], events: [], showsLooseEnds: true)
  #expect(document.text(for: .looseEndText(looseEnd.looseEnd.id)) == "ship the find bar")
}

@Test func documentOrderFollowsOnScreenOrderWithATranslatedLooseEnd() {
  // The on-screen-order contract (documentOrderFollowsOnScreenOrder above) must hold whether the
  // loose end's text is translated or not — translation swaps the TEXT of a slot, never its position.
  let node = makeNode(name: "Pensieve", description: "a recall tool")
  let looseEnd = makeLooseEndView(text: "ship the find bar", quote: "we should ship the find bar")
  let event = makeEvent(summary: "feat: find bar")
  let document = NodeFindDocument.make(node: node, narration: "worked on find",
                                       looseEnds: [looseEnd], events: [event], showsLooseEnds: true,
                                       translatedLooseEndText: [looseEnd.looseEnd.id: "die Suchleiste versenden"])
  let anchors = document.units.map(\.anchor)
  #expect(anchors.first == .nodeName)
  #expect(anchors[1] == .description)
  #expect(anchors[2] == .looseEndText(looseEnd.looseEnd.id))
  #expect(anchors[3] == .narration)
  #expect(anchors.last == .event(event.id))
  #expect(document.units[2].text == "die Suchleiste versenden")
}

@Test func onlyAnchorsBehindTheDisclosureRequireExpandingTheRow() {
  let looseEndID = UUID()
  // The loose end's own text renders in the row's always-visible header, so find must NOT throw the
  // provenance box open to reach it — only the quote fallback and the transcript segments live there.
  #expect(FindAnchor.looseEndText(looseEndID).looseEndIDRequiringExpansion == nil)
  #expect(FindAnchor.looseEndQuote(looseEndID).looseEndIDRequiringExpansion == looseEndID)
  #expect(FindAnchor.transcriptSegment(looseEndID: looseEndID, messageIndex: 3, segment: 0)
            .looseEndIDRequiringExpansion == looseEndID)
  #expect(FindAnchor.nodeName.looseEndIDRequiringExpansion == nil)
  #expect(FindAnchor.narration.looseEndIDRequiringExpansion == nil)
  #expect(FindAnchor.description.looseEndIDRequiringExpansion == nil)
  #expect(FindAnchor.event(UUID()).looseEndIDRequiringExpansion == nil)
}
