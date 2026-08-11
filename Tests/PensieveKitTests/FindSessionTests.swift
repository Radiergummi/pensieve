// Tests/PensieveKitTests/FindSessionTests.swift
import Foundation
import Testing
@testable import PensieveKit

/// A document of plain units, built directly so these tests exercise navigation, not construction.
private func document(_ pairs: [(FindAnchor, String)]) -> NodeFindDocument {
  NodeFindDocument.testing(units: pairs.map { FindUnit(anchor: $0.0, text: $0.1) })
}

@Test func nextWrapsAroundAndPreviousWrapsBackward() {
  var session = FindSession(document: document([(.nodeName, "sync"), (.description, "sync sync")]))
  session.setQuery("sync")
  #expect(session.matchCount == 3)
  #expect(session.currentOrdinal == 1)
  session.next(); #expect(session.currentOrdinal == 2)
  session.next(); #expect(session.currentOrdinal == 3)
  session.next(); #expect(session.currentOrdinal == 1)   // wraps
  session.previous(); #expect(session.currentOrdinal == 3)
}

@Test func aFillThatInsertsEarlierMatchesKeepsTheUserOnTheSameMatch() {
  // The whole reason identity is tracked instead of an ordinal.
  let looseEndID = UUID()
  let eventID = UUID()   // held across both documents — the same event, unlike the loose end's fill
  var session = FindSession(document: document([(.looseEndText(looseEndID), "sync"),
                                                (.event(eventID), "sync")]))
  session.setQuery("sync")
  session.next()
  let heldIdentity = session.current?.identity
  #expect(session.currentOrdinal == 2)

  // A provenance fill lands EARLIER in document order, adding two matches ahead of the user.
  session.update(document: document([(.looseEndText(looseEndID), "sync"),
                                     (.transcriptSegment(looseEndID: looseEndID, messageIndex: 1,
                                                         segment: 0), "sync sync"),
                                     (.event(eventID), "sync")]))
  #expect(session.current?.identity == heldIdentity)   // same match…
  #expect(session.currentOrdinal == 4)                 // …renumbered, not moved
  #expect(session.matchCount == 4)
}

@Test func whenTheCurrentMatchVanishesItReanchorsToTheSameListPosition() {
  var session = FindSession(document: document([(.narration, "sync one"), (.event(UUID()), "sync two")]))
  session.setQuery("sync")
  session.next()
  #expect(session.currentOrdinal == 2)
  // ⌘R replaces the narration with different prose: the .narration match is gone.
  session.update(document: document([(.event(UUID()), "sync two")]))
  #expect(session.currentOrdinal == 1)                 // clamped, never nil-while-matches-exist
  #expect(session.matchCount == 1)
}

@Test func changingTheQueryResetsToTheFirstMatch() {
  var session = FindSession(document: document([(.nodeName, "alpha beta"), (.description, "beta")]))
  session.setQuery("beta")
  session.next()
  #expect(session.currentOrdinal == 2)
  session.setQuery("alpha")
  #expect(session.matchCount == 1)
  #expect(session.currentOrdinal == 1)
}

@Test func anEmptyQueryYieldsNoMatchesAndNoCurrent() {
  var session = FindSession(document: document([(.nodeName, "sync")]))
  session.setQuery("")
  #expect(session.matchCount == 0)
  #expect(session.current == nil)
  #expect(!session.hasMatches)
  session.next()                       // must not crash
  #expect(session.current == nil)
}

@Test func clearDropsQueryAndMatches() {
  var session = FindSession(document: document([(.nodeName, "sync")]))
  session.setQuery("sync")
  session.clear()
  #expect(session.query.isEmpty)
  #expect(session.matchCount == 0)
}
