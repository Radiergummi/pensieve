// Tests/PensieveKitTests/GoldSetTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Test func goldSetRoundTripsAndScoresRecall() throws {
  var goldSet = GoldSet(recall: ["x1": ["revisit retries", "call Bob"]], grounding: [:])
  let url = tempURL("gold", ext: "json")
  try goldSet.save(to: url)
  let loaded = GoldSet.load(from: url)
  // surfaced hits one of two known → recall 0.5
  #expect(loaded.recallScore(itemID: "x1", surfaced: ["revisit retries"]) == 0.5)
  #expect(loaded.recallScore(itemID: "unknown", surfaced: []) == nil)
}

@Test func goldSetLoadMissingIsEmpty() {
  let goldSet = GoldSet.load(from: tempURL("nope", ext: "json"))
  #expect(goldSet.recall.isEmpty && goldSet.grounding.isEmpty)
}
