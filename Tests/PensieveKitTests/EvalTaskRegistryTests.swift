import Testing
@testable import PensieveKit

private struct StubTask: EvalTask {
  let id: String; let scorer: ScorerKind = .rubric(dimensions: ["x"])
  func run(item: CorpusItem, model: any LLMProvider, reference: any LLMProvider) async throws -> TaskOutput { .init(text: "", looseEnds: nil) }
}

@Test func consistencyFlagsTaskWithoutBar() {
  let cfg = EvalConfig(roster: [], referenceProvider: "r",
                       judge: ModelSpec(label:"j",kind:"cloud",flavor:.anthropic,baseURL:"b",model:"m",inputPricePerM:1,outputPricePerM:1),
                       bars: [TaskBar(task: "narration", inheritFromIncumbent: true, precision: nil, recall: nil, quality: nil)],
                       corpusSize: 10, corpusSeed: 1, noiseMargin: 0.03)
  let problems = TaskRegistry.consistency(tasks: [StubTask(id: "extraction"), StubTask(id: "narration")], config: cfg)
  #expect(problems.contains { $0.contains("extraction") }) // no bar for extraction
}
