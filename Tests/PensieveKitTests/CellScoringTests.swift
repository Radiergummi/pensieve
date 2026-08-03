import Testing
@testable import PensieveKit

private struct StubProvider: LLMProvider {
  func complete(prompt: String) async throws -> String { "" }
}

private func makeSpec(label: String = "m") -> ModelSpec {
  ModelSpec(label: label, kind: "foundationModels", flavor: nil, baseURL: nil, model: nil,
            inputPricePerM: 0, outputPricePerM: 0)
}

@Test func outcomeExclusionDoesNotDragDownExtractionRecall() async {
  let gold = GoldSet(recall: ["x1": ["a", "b"]], grounding: [:])
  let judge = Judge(provider: StubProvider())
  let spec = makeSpec()

  let goodSample = CellSample(task: "extraction", modelLabel: "m", itemID: "x1", outputText: "",
                              looseEndQuotes: ["a", "b"], latencyMS: 10, estInputTokens: 0,
                              estOutputTokens: 0, outcome: "success")
  let failedSample = CellSample(task: "extraction", modelLabel: "m", itemID: "x1", outputText: "",
                                looseEndQuotes: nil, latencyMS: 0, estInputTokens: 0,
                                estOutputTokens: 0, outcome: "providerError")

  let scoreA = await CellScoring.score(task: ExtractionTask(), items: [], samples: [goodSample],
                                       spec: spec, references: ScoringReferences(gold: gold, judge: judge))
  let scoreB = await CellScoring.score(task: ExtractionTask(), items: [], samples: [goodSample, failedSample],
                                       spec: spec, references: ScoringReferences(gold: gold, judge: judge))

  #expect(scoreA.recall == 1.0)
  #expect(scoreB.recall == 1.0)
  #expect(scoreA.recall == scoreB.recall)
}

@Test func allFailedSamplesYieldNilExtractionScores() async {
  let gold = GoldSet(recall: ["x1": ["a", "b"]], grounding: [:])
  let judge = Judge(provider: StubProvider())
  let spec = makeSpec()

  let failedSample = CellSample(task: "extraction", modelLabel: "m", itemID: "x1", outputText: "",
                                looseEndQuotes: nil, latencyMS: 0, estInputTokens: 0,
                                estOutputTokens: 0, outcome: "providerError")

  let score = await CellScoring.score(task: ExtractionTask(), items: [], samples: [failedSample],
                                      spec: spec, references: ScoringReferences(gold: gold, judge: judge))

  #expect(score.precision == nil)
  #expect(score.recall == nil)
  #expect(score.costUSD == 0)
  #expect(score.latencyP50 == 0)
  #expect(score.reproducedFabrication == false)
}

@Test func allFailedSamplesYieldNilRubricQuality() async {
  let gold = GoldSet(recall: [:], grounding: [:])
  let judge = Judge(provider: StubProvider())
  let spec = makeSpec()

  let failedSample = CellSample(task: "narration", modelLabel: "m", itemID: "n1", outputText: "",
                                looseEndQuotes: nil, latencyMS: 0, estInputTokens: 0,
                                estOutputTokens: 0, outcome: "providerError")

  let score = await CellScoring.score(task: NarrationTask(), items: [], samples: [failedSample],
                                      spec: spec, references: ScoringReferences(gold: gold, judge: judge))

  #expect(score.quality == nil)
}
