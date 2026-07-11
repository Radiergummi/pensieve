// Tests/PensieveKitTests/DecisionEngineTests.swift
import Testing
@testable import PensieveKit

private func score(_ label: String, onDevice: Bool, q: Double, cost: Double, lat: Double, fab: Bool = false, prec: Double? = nil, rec: Double? = nil) -> CellScore {
  CellScore(modelLabel: label, isOnDevice: onDevice, quality: q, precision: prec, recall: rec, costUSD: cost, latencyP50: lat, reproducedFabrication: fab)
}

@Test func medianAndMajority() {
  #expect(Aggregate.median([1, 3, 2]) == 2)
  #expect(Aggregate.median([]) == nil)
  #expect(Aggregate.majorityFabrication([true, true, false]) == true)
  #expect(Aggregate.majorityFabrication([true, false, false]) == false)
}

@Test func localIncumbentThatClearsAlwaysWinsEvenIfCloudScoresHigher() {
  // Local-first north star: quality above the bar is worth nothing. FM clears → FM wins.
  let scores = [score("apple/fm", onDevice: true, q: 0.80, cost: 0, lat: 900),
                score("openai/nano", onDevice: false, q: 0.95, cost: 0.001, lat: 300)]
  let bar = EffectiveBar(precision: nil, recall: nil, quality: 0.70)
  let rec = DecisionEngine.recommend(task: "narration", scores: scores, bar: bar, incumbentLabel: "apple/fm", noiseMargin: 0.03)
  #expect(rec.winner == "apple/fm")
}

@Test func challengerWinsWhenIncumbentFailsTheBar() {
  // Absolute (config) bar the incumbent misses → cheapest-passing challenger wins.
  let scores = [score("apple/fm", onDevice: true, q: 0.60, cost: 0, lat: 900),
                score("openai/nano", onDevice: false, q: 0.90, cost: 0.001, lat: 300)]
  let bar = EffectiveBar(precision: nil, recall: nil, quality: 0.85)
  let rec = DecisionEngine.recommend(task: "narration", scores: scores, bar: bar, incumbentLabel: "apple/fm", noiseMargin: 0.03)
  #expect(rec.winner == "openai/nano")     // FM (0.60) excluded; nano (0.90) clears 0.85 by margin
  #expect(rec.clearedBar == ["openai/nano"])
}

@Test func fallsBackToIncumbentWhenNothingClears() {
  let scores = [score("apple/fm", onDevice: true, q: 0.50, cost: 0, lat: 900),
                score("openai/nano", onDevice: false, q: 0.55, cost: 0.001, lat: 300)]
  let bar = EffectiveBar(precision: nil, recall: nil, quality: 0.90)
  let rec = DecisionEngine.recommend(task: "narration", scores: scores, bar: bar, incumbentLabel: "apple/fm", noiseMargin: 0.03)
  #expect(rec.winner == "apple/fm")        // nobody cleared → incumbent fallback
}

@Test func fabricationHardFailsExtractionRegardlessOfQuality() {
  let scores = [score("apple/fm", onDevice: true, q: 0, cost: 0, lat: 900, prec: 1.0, rec: 0.8),
                score("grok/fast", onDevice: false, q: 0, cost: 0.001, lat: 200, fab: true, prec: 0.99, rec: 0.95)]
  let bar = EffectiveBar(precision: 1.0, recall: 0.8, quality: nil)
  let rec = DecisionEngine.recommend(task: "extraction", scores: scores, bar: bar, incumbentLabel: "apple/fm", noiseMargin: 0.03)
  #expect(rec.clearedBar.contains("grok/fast") == false) // reproduced fabrication → excluded
  #expect(rec.winner == "apple/fm")
}

@Test func localityBreaksTiesAmongClearingChallengers() {
  // both clear the bar and beat incumbent; cheaper-but-online vs on-device-that-also-clears
  let scores = [score("apple/fm", onDevice: true, q: 0.95, cost: 0, lat: 900),
                score("openai/nano", onDevice: false, q: 0.97, cost: 0.001, lat: 200)]
  let bar = EffectiveBar(precision: nil, recall: nil, quality: 0.70)
  let rec = DecisionEngine.recommend(task: "narration", scores: scores, bar: bar, incumbentLabel: "zzz-not-in-set", noiseMargin: 0.03)
  #expect(rec.winner == "apple/fm") // locality first among bar-clearing models
}
