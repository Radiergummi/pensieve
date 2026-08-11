// Tests/PensieveKitTests/SnippetMakerTests.swift
import Foundation
import Testing
@testable import PensieveKit

@Test func snippetMatchAtStart() {
  let snippet = SnippetMaker.make(from: "hello world", matching: "hello")
  #expect(snippet.leading == "")
  #expect(snippet.match == "hello")
  #expect(snippet.trailing == " world")
}

@Test func snippetMatchInMiddle() {
  let snippet = SnippetMaker.make(from: "the quick brown fox", matching: "quick")
  #expect(snippet.leading == "the ")
  #expect(snippet.match == "quick")
  #expect(snippet.trailing == " brown fox")
}

@Test func snippetMatchAtEnd() {
  let snippet = SnippetMaker.make(from: "abc xyz", matching: "xyz")
  #expect(snippet.leading == "abc ")
  #expect(snippet.match == "xyz")
  #expect(snippet.trailing == "")
}

@Test func snippetIsCaseInsensitiveAndKeepsSourceCase() {
  let snippet = SnippetMaker.make(from: "Deploy the App", matching: "deploy")
  #expect(snippet.match == "Deploy")   // original case preserved
}

@Test func snippetTakesFirstOccurrence() {
  let snippet = SnippetMaker.make(from: "cat dog cat", matching: "cat")
  #expect(snippet.leading == "")
  #expect(snippet.match == "cat")
  #expect(snippet.trailing == " dog cat")
}

@Test func snippetNoMatchReturnsSourceInLeading() {
  let snippet = SnippetMaker.make(from: "hello", matching: "zzz")
  #expect(snippet.leading == "hello")
  #expect(snippet.match == "")
  #expect(snippet.trailing == "")
}

@Test func snippetRoundTrips() {
  let snippet = SnippetMaker.make(from: "the quick brown fox", matching: "quick")
  #expect(snippet.leading + snippet.match + snippet.trailing == "the quick brown fox")
}

@Test func snippetWindowsLongSidesAndKeepsMatchExact() {
  let source = String(repeating: "a", count: 200) + "NEEDLE" + String(repeating: "b", count: 200)
  let snippet = SnippetMaker.make(from: source, matching: "needle", window: 10)
  #expect(snippet.match == "NEEDLE")
  #expect(snippet.leading.hasPrefix("…"))
  #expect(snippet.trailing.hasSuffix("…"))
  #expect(snippet.leading.count <= 11)   // "…" + 10
  #expect(snippet.trailing.count <= 11)
}

@Test func snippetUnicodeSafe() {
  let snippet = SnippetMaker.make(from: "😀😀 needle 🚀", matching: "needle")
  #expect(snippet.leading == "😀😀 ")
  #expect(snippet.match == "needle")
  #expect(snippet.trailing == " 🚀")
}

@Test func matchingAnyHighlightsTheFirstTermThatActuallyMatches() {
  let snippet = SnippetMaker.make(from: "the quick brown fox", matchingAny: ["absent", "brown"])
  #expect(snippet.match == "brown")
}

/// The FTS5 index folds diacritics (`remove_diacritics 2`), so `losung` really does retrieve
/// `Lösung` — the highlighter must fold too, or a genuine hit renders with nothing highlighted.
/// The ORIGINAL spelling is what gets displayed.
@Test func snippetMatchesAcrossFoldedDiacritics() {
  let snippet = SnippetMaker.make(from: "Lösung finden", matching: "losung")
  #expect(snippet.match == "Lösung")
  #expect(snippet.leading + snippet.match + snippet.trailing == "Lösung finden")
}

/// Same rule reached through the term-list path: `uber` folds onto `über`, so the FIRST term wins
/// here. Pins the folding, not merely the loop — under a case-only comparison `über` would not match
/// and the highlight would land on `sync` instead.
@Test func matchingAnyFoldsDiacriticsWhenPickingTheTerm() {
  let snippet = SnippetMaker.make(from: "über sync agent", matchingAny: ["uber", "sync"])
  #expect(snippet.match == "über")
}

@Test func matchingAnyWithNoMatchingTermYieldsAHeadWindow() {
  let snippet = SnippetMaker.make(from: "the quick brown fox", matchingAny: ["absent", ""])
  #expect(snippet.match == "")
  #expect(snippet.leading == "the quick brown fox")
}
