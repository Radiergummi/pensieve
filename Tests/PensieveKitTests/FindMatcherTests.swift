// Tests/PensieveKitTests/FindMatcherTests.swift
import Foundation
import Testing
@testable import PensieveKit

@Test func findsEveryOccurrenceLeftToRight() {
  let source = "sync the sync gap and sync again"
  let ranges = FindMatcher.ranges(in: source, query: "sync")
  #expect(ranges.count == 3)
  #expect(source[ranges[0]] == "sync")
  #expect(ranges[0].lowerBound < ranges[1].lowerBound)
  #expect(ranges[1].lowerBound < ranges[2].lowerBound)
}

@Test func matchingIsCaseAndDiacriticInsensitive() {
  // Agrees with the FTS5 remove_diacritics 2 tokenizer: typing `losung` must find `Lösung`.
  let ranges = FindMatcher.ranges(in: "Die Lösung war einfach", query: "losung")
  #expect(ranges.count == 1)
  #expect("Die Lösung war einfach"[ranges[0]] == "Lösung")
}

@Test func emptyQueryOrEmptySourceYieldsNoRanges() {
  #expect(FindMatcher.ranges(in: "anything", query: "").isEmpty)
  #expect(FindMatcher.ranges(in: "", query: "anything").isEmpty)
}

@Test func adjacentOccurrencesAreBothFound() {
  let ranges = FindMatcher.ranges(in: "abab", query: "ab")
  #expect(ranges.count == 2)
}

@Test func overlappingCandidatesDoNotDoubleCount() {
  // "aaa" contains "aa" at offsets 0 and 1; non-overlapping left-to-right yields exactly one.
  let ranges = FindMatcher.ranges(in: "aaa", query: "aa")
  #expect(ranges.count == 1)
}

@Test func runsRoundTripToTheSource() {
  let source = "fix the sync gap before the sync ships"
  let runs = FindMatcher.runs(in: source, ranges: FindMatcher.ranges(in: source, query: "sync"))
  let rebuilt = runs.map { run in
    switch run { case .plain(let text), .match(let text): return text }
  }.joined()
  #expect(rebuilt == source)
  #expect(runs.filter { if case .match = $0 { return true } else { return false } }.count == 2)
}

@Test func runsWithNoRangesIsASinglePlainRun() {
  let runs = FindMatcher.runs(in: "nothing here", ranges: [])
  #expect(runs == [.plain("nothing here")])
}

@Test func snippetMakerStillProducesTheSameHighlightAfterUnification() {
  // Regression pin on the SHIPPED search-results highlight — Snippet is the N=1 case of FindMatcher.
  let snippet = SnippetMaker.make(from: "the quick brown fox", matching: "quick")
  #expect(snippet.leading == "the ")
  #expect(snippet.match == "quick")
  #expect(snippet.trailing == " brown fox")
  #expect(snippet.leading + snippet.match + snippet.trailing == "the quick brown fox")
}
