// Tests/PensieveKitTests/SnippetMakerTests.swift
import Foundation
import Testing
@testable import PensieveKit

@Test func snippetMatchAtStart() {
  let s = SnippetMaker.make(from: "hello world", matching: "hello")
  #expect(s.leading == "")
  #expect(s.match == "hello")
  #expect(s.trailing == " world")
}

@Test func snippetMatchInMiddle() {
  let s = SnippetMaker.make(from: "the quick brown fox", matching: "quick")
  #expect(s.leading == "the ")
  #expect(s.match == "quick")
  #expect(s.trailing == " brown fox")
}

@Test func snippetMatchAtEnd() {
  let s = SnippetMaker.make(from: "abc xyz", matching: "xyz")
  #expect(s.leading == "abc ")
  #expect(s.match == "xyz")
  #expect(s.trailing == "")
}

@Test func snippetIsCaseInsensitiveAndKeepsSourceCase() {
  let s = SnippetMaker.make(from: "Deploy the App", matching: "deploy")
  #expect(s.match == "Deploy")   // original case preserved
}

@Test func snippetTakesFirstOccurrence() {
  let s = SnippetMaker.make(from: "cat dog cat", matching: "cat")
  #expect(s.leading == "")
  #expect(s.match == "cat")
  #expect(s.trailing == " dog cat")
}

@Test func snippetNoMatchReturnsSourceInLeading() {
  let s = SnippetMaker.make(from: "hello", matching: "zzz")
  #expect(s.leading == "hello")
  #expect(s.match == "")
  #expect(s.trailing == "")
}

@Test func snippetRoundTrips() {
  let s = SnippetMaker.make(from: "the quick brown fox", matching: "quick")
  #expect(s.leading + s.match + s.trailing == "the quick brown fox")
}

@Test func snippetWindowsLongSidesAndKeepsMatchExact() {
  let source = String(repeating: "a", count: 200) + "NEEDLE" + String(repeating: "b", count: 200)
  let s = SnippetMaker.make(from: source, matching: "needle", window: 10)
  #expect(s.match == "NEEDLE")
  #expect(s.leading.hasPrefix("…"))
  #expect(s.trailing.hasSuffix("…"))
  #expect(s.leading.count <= 11)   // "…" + 10
  #expect(s.trailing.count <= 11)
}

@Test func snippetUnicodeSafe() {
  let s = SnippetMaker.make(from: "😀😀 needle 🚀", matching: "needle")
  #expect(s.leading == "😀😀 ")
  #expect(s.match == "needle")
  #expect(s.trailing == " 🚀")
}
