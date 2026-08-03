// Tests/PensieveKitTests/DecisionEngineTests.swift
import Testing
@testable import PensieveKit

private func score(
  _ label: String, onDevice: Bool, quality: Double, cost: Double, lat: Double,
  fab: Bool = false, prec: Double? = nil, rec: Double? = nil
) -> CellScore {
  CellScore(
    modelLabel: label, isOnDevice: onDevice, quality: quality, precision: prec,
    recall: rec, costUSD: cost, latencyP50: lat, reproducedFabrication: fab
  )
}

@Test func medianAndMajority() {
  #expect(Aggregate.median([1, 3, 2]) == 2)
  #expect(Aggregate.median([]) == nil)
  #expect(Aggregate.majorityFabrication([true, true, false]) == true)
  #expect(Aggregate.majorityFabrication([true, false, false]) == false)
}

@Test func localIncumbentThatClearsAlwaysWinsEvenIfCloudScoresHigher() {
  // Local-first north star: quality above the bar is worth nothing. FM clears → FM wins.
  let scores = [score("apple/fm", onDevice: true, quality: 0.80, cost: 0, lat: 900),
                score("openai/nano", onDevice: false, quality: 0.95, cost: 0.001, lat: 300)]
  let bar = EffectiveBar(precision: nil, recall: nil, quality: 0.70)
  let rec = DecisionEngine.recommend(task: "narration", scores: scores, bar: bar, incumbentLabel: "apple/fm", noiseMargin: 0.03)
  #expect(rec.winner == "apple/fm")
}

@Test func challengerWinsWhenIncumbentFailsTheBar() {
  // Absolute (config) bar the incumbent misses → cheapest-passing challenger wins.
  let scores = [score("apple/fm", onDevice: true, quality: 0.60, cost: 0, lat: 900),
                score("openai/nano", onDevice: false, quality: 0.90, cost: 0.001, lat: 300)]
  let bar = EffectiveBar(precision: nil, recall: nil, quality: 0.85)
  let rec = DecisionEngine.recommend(task: "narration", scores: scores, bar: bar, incumbentLabel: "apple/fm", noiseMargin: 0.03)
  #expect(rec.winner == "openai/nano")     // FM (0.60) excluded; nano (0.90) clears 0.85 by margin
  #expect(rec.clearedBar == ["openai/nano"])
}

@Test func fallsBackToIncumbentWhenNothingClears() {
  let scores = [score("apple/fm", onDevice: true, quality: 0.50, cost: 0, lat: 900),
                score("openai/nano", onDevice: false, quality: 0.55, cost: 0.001, lat: 300)]
  let bar = EffectiveBar(precision: nil, recall: nil, quality: 0.90)
  let rec = DecisionEngine.recommend(task: "narration", scores: scores, bar: bar, incumbentLabel: "apple/fm", noiseMargin: 0.03)
  #expect(rec.winner == "apple/fm")        // nobody cleared → incumbent fallback
}

@Test func fabricationHardFailsExtractionRegardlessOfQuality() {
  // grok clears the ORDINARY bar (precision 1.0, recall 0.9 > 0.8+margin) and would otherwise
  // land in clearedBar — it is excluded ONLY because it reproduced a fabrication. apple/fm clears
  // cleanly. Deleting the fabrication hard-gate would put grok in clearedBar and fail this test.
  let scores = [score("apple/fm", onDevice: true, quality: 0, cost: 0, lat: 900, prec: 1.0, rec: 0.9),
                score("grok/fast", onDevice: false, quality: 0, cost: 0.001, lat: 200, fab: true, prec: 1.0, rec: 0.9)]
  let bar = EffectiveBar(precision: 1.0, recall: 0.8, quality: nil)
  let rec = DecisionEngine.recommend(task: "extraction", scores: scores, bar: bar, incumbentLabel: "apple/fm", noiseMargin: 0.03)
  #expect(rec.clearedBar.contains("grok/fast") == false) // reproduced fabrication → excluded despite clearing the ordinary bar
  #expect(rec.clearedBar.contains("apple/fm") == true)   // apple/fm clears cleanly
  #expect(rec.winner == "apple/fm")
}

@Test func qualityWithinNoiseMarginDoesNotClear() {
  // quality 0.72 is above the bar (0.70) but NOT above bar+noiseMargin (0.73) → must NOT clear.
  let scores = [score("openai/nano", onDevice: false, quality: 0.72, cost: 0.001, lat: 300)]
  let bar = EffectiveBar(precision: nil, recall: nil, quality: 0.70)
  let rec = DecisionEngine.recommend(task: "narration", scores: scores, bar: bar, incumbentLabel: "apple/fm", noiseMargin: 0.03)
  #expect(rec.clearedBar.isEmpty)      // 0.72 < 0.70+0.03 → does not robustly clear
  #expect(rec.winner == "apple/fm")    // nobody cleared → incumbent fallback
}

@Test func localityBreaksTiesAmongClearingChallengers() {
  // both clear the bar and beat incumbent; cheaper-but-online vs on-device-that-also-clears
  let scores = [score("apple/fm", onDevice: true, quality: 0.95, cost: 0, lat: 900),
                score("openai/nano", onDevice: false, quality: 0.97, cost: 0.001, lat: 200)]
  let bar = EffectiveBar(precision: nil, recall: nil, quality: 0.70)
  let rec = DecisionEngine.recommend(task: "narration", scores: scores, bar: bar, incumbentLabel: "zzz-not-in-set", noiseMargin: 0.03)
  #expect(rec.winner == "apple/fm") // locality first among bar-clearing models
}
