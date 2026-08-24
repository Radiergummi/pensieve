import Testing
import Foundation
@testable import PensieveKit

/// The fixes that make `pensieve eval run` usable on a machine with a Claude subscription and no API
/// key (findings 2.6, 2.16, 2.22, 2.23, 2.25), plus the cost axis they share.
@Suite struct EvalHarnessUsabilityTests {
  private func spec(_ label: String, kind: String, inputPrice: Double = 0,
                    outputPrice: Double = 0) -> ModelSpec {
    ModelSpec(label: label, kind: kind, inputPricePerM: inputPrice, outputPricePerM: outputPrice)
  }

  // MARK: - 2.6 — the subscription provider is nameable, and no key ends only the judge

  @Test func claudeCLIIsARosterKindThatNeedsNoKey() {
    let subscription = spec("claude-subscription", kind: ModelSpec.claudeCLIKind)
    #expect(ModelProviderFactory.needsKey(subscription) == false)
    #expect(ModelProviderFactory.make(subscription, apiKey: nil) is ClaudeCLIProvider)
    // Local process, cloud inference: it must NOT claim the local-first privilege.
    #expect(subscription.isOnDevice == false)
    // A cloud spec with no key still refuses, so the exemption is narrow.
    let cloud = spec("openai/x", kind: ModelSpec.cloudKind)
    #expect(ModelProviderFactory.needsKey(cloud) == true)
    #expect(ModelProviderFactory.make(cloud, apiKey: nil) == nil)
  }

  /// A missing judge must cost only the judge-scored tasks. Extraction is graded against the frozen
  /// gold set, so its scores have to survive `judge == nil` intact — that is what makes the sweep
  /// runnable at all on this machine.
  @Test func goldScoredTasksScoreFullyWithNoJudge() async {
    let gold = GoldSet(recall: ["x1": ["a", "b"]],
                       grounding: ["x1": [CandidateLabel(quote: "a", grounded: true),
                                          CandidateLabel(quote: "z", grounded: false)]])
    let sample = CellSample(task: "extraction", modelLabel: "m", itemID: "x1", outputText: "out",
                            looseEndQuotes: ["a", "b"], latencyMS: 10, estInputTokens: 100,
                            estOutputTokens: 10, outcome: "success")
    let score = await CellScoring.score(task: ExtractionTask(), items: [], samples: [sample],
                                        spec: spec("m", kind: ModelSpec.foundationModelsKind),
                                        references: ScoringReferences(gold: gold, judge: nil))
    #expect(score.recall == 1.0)
    #expect(score.precision == 1.0)
    #expect(score.reproducedFabrication == false)
  }

  /// And a judge-scored task with no judge reports quality UNKNOWN, never zero — otherwise a missing
  /// API key would read as "every model writes badly" and `DecisionEngine` would act on it.
  @Test func judgeScoredTasksReportUnknownQualityWithNoJudge() async {
    let sample = CellSample(task: "narration", modelLabel: "m", itemID: "n1", outputText: "prose",
                            looseEndQuotes: nil, latencyMS: 10, estInputTokens: 100,
                            estOutputTokens: 10, outcome: "success")
    let score = await CellScoring.score(task: NarrationTask(), items: [], samples: [sample],
                                        spec: spec("m", kind: ModelSpec.foundationModelsKind),
                                        references: ScoringReferences(gold: GoldSet(recall: [:], grounding: [:]),
                                                                      judge: nil))
    #expect(score.quality == nil)
    // The axes that do not need a judge are still reported.
    #expect(score.latencyP50 == 10)
  }

  // MARK: - 2.23 — the guardrail covers registry ↔ corpus, not just registry ↔ config

  @Test func aTaskWithNoCorpusPoolIsReportedAsAProblem() {
    let bars = (TaskRegistry.all.map { $0.id } + ["summarization"]).map {
      TaskBar(task: $0, inheritFromIncumbent: true, precision: nil, recall: nil, quality: nil)
    }
    let config = EvalConfig(roster: [], referenceProvider: "on-device",
                            judge: spec("judge", kind: ModelSpec.foundationModelsKind),
                            bars: bars, corpusSize: 20, corpusSeed: 0, noiseMargin: 0.05)
    let problems = TaskRegistry.consistency(tasks: TaskRegistry.all + [SummarizationTask()],
                                            config: config)
    #expect(problems.contains { $0.contains("summarization") && $0.contains("corpus pool") })
    // The shipped registry, against the shipped corpus pools, is clean on BOTH axes.
    #expect(TaskRegistry.all.allSatisfy { CorpusBuilder.taskFolders.contains($0.id) })
  }

  // MARK: - 2.16 / 2.25 — a swallowed provider failure, and the input side of the cost axis

  /// `SummaryBuilder.narrate` folds a provider throw into nil, so `NarrationTask` returns "" and
  /// throws nothing — the run USED to be recorded as `success`, i.e. a dead provider scored as a
  /// model that writes nothing. The throw is instead observed at the seam it crosses, exactly the
  /// composition `Runner.runCell` performs.
  @Test func aProviderThrowSwallowedByTheProductionPathIsNotScoredAsSuccess() async throws {
    let measured = MeasuredProvider(ThrowingProvider())
    let output = try await NarrationTask().run(item: narrationItem(), model: measured,
                                               reference: ThrowingProvider())
    #expect(output.text == "")                  // indistinguishable from a bad model, on its own
    #expect(measured.providerFailed == true)    // …but the seam saw the throw
    #expect(RunOutcome.classify(nil, providerFailed: measured.providerFailed) == "providerError")
    // The prompt was built and sent, so it lands on the cost axis even though the call failed.
    #expect(measured.estInputTokens > 0)
  }

  /// A GENUINELY empty answer from a working provider stays a success — otherwise the fix above
  /// would just relabel every bad model as broken infrastructure.
  @Test func anEmptyAnswerFromAWorkingProviderStaysASuccess() async throws {
    let measured = MeasuredProvider(EmptyAnswerProvider())
    let output = try await NarrationTask().run(item: narrationItem(), model: measured,
                                               reference: EmptyAnswerProvider())
    #expect(output.text == "")
    #expect(measured.providerFailed == false)
    #expect(RunOutcome.classify(nil, providerFailed: measured.providerFailed) == "success")
  }

  /// Unlike narration, description calls the provider directly, so it can PROPAGATE the throw and
  /// let `RunOutcome` tell a parse failure from a provider failure. It used to `try?` it into "".
  @Test func descriptionPropagatesAProviderThrowRatherThanReturningEmptyText() async {
    let item = CorpusItem.description(DescriptionCorpusItem(
      id: UUID().uuidString,
      context: ProjectContextDTO(ProjectContext(dirName: "pensieve", gitRemote: nil,
                                                readmeHead: "A recall tool.", claudeMdHead: nil,
                                                manifest: nil))))
    await #expect(throws: LLMError.self) {
      _ = try await DescriptionTask().run(item: item, model: ThrowingProvider(),
                                          reference: ThrowingProvider())
    }
  }

  @Test func inputTokensAreCountedAtTheProviderSeamAndPricedIn() async throws {
    let modelSpec = spec("m", kind: ModelSpec.cloudKind, inputPrice: 10, outputPrice: 10)
    let measured = MeasuredProvider(EchoProvider())
    let output = try await NarrationTask().run(item: narrationItem(), model: measured,
                                               reference: EchoProvider())
    #expect(measured.estInputTokens > 0)

    let sample = CellSample(task: "narration", modelLabel: "m", itemID: "n1",
                            outputText: output.text, looseEndQuotes: nil, latencyMS: 1,
                            estInputTokens: measured.estInputTokens,
                            estOutputTokens: TokenEstimate.tokens(output.text), outcome: "success")
    let score = await CellScoring.score(task: NarrationTask(), items: [], samples: [sample],
                                        spec: modelSpec,
                                        references: ScoringReferences(gold: GoldSet(recall: [:], grounding: [:]),
                                                                      judge: nil))
    // Priced with the real prompt, the cell costs strictly more than the output-only figure the
    // scorer used to compute from `inputText: ""` — the long-prompt model no longer looks free.
    let outputOnly = TokenEstimate.costUSD(inputTokens: 0, outputTokens: sample.estOutputTokens,
                                           spec: modelSpec)
    #expect(score.costUSD > outputOnly)
  }

  /// One wrapper sums EVERY call, including the structured ones the on-device provider overrides —
  /// extraction makes several per item, and counting only `complete` would undercount them all.
  @Test func everyProviderCallCountsTowardTheInputSide() async throws {
    let measured = MeasuredProvider(EchoProvider())
    _ = try await measured.complete(prompt: String(repeating: "x", count: 400))
    let afterFirst = measured.estInputTokens
    _ = try? await measured.classifyGenuineIndices(prompt: String(repeating: "y", count: 400))
    #expect(measured.estInputTokens > afterFirst)
  }

  @Test func classifyReportsAProviderFailureEvenWithNoThrownError() {
    #expect(RunOutcome.classify(nil) == "success")
    #expect(RunOutcome.classify(nil, providerFailed: true) == "providerError")
    #expect(RunOutcome.classify(LLMError.providerFailed("not parseable")) == "parseFail")
  }

  private func narrationItem() -> CorpusItem {
    let nodeID = UUID(), sourceID = UUID()
    let event = Event(nodeID: nodeID, sourceID: sourceID, occurredAt: Date(),
                      kind: CaptureKind.gitCommit,
                      summary: "wire the retry into the ingester so a dead path is retried",
                      detailJSON: "{}", fingerprint: "f1")
    return .narration(NarrationCorpusItem(id: nodeID.uuidString, nodeName: "Pensieve",
                                          events: [EventDTO(event)]))
  }
}

/// A registered task with no corpus pool — the exact shape finding 2.23 describes.
private struct SummarizationTask: EvalTask {
  let id = "summarization"
  let scorer: ScorerKind = .rubric(dimensions: ["concise"])
  func run(item: CorpusItem, model: any LLMProvider, reference: any LLMProvider) async throws -> TaskOutput {
    TaskOutput(text: "", looseEnds: nil)
  }
}

private struct ThrowingProvider: LLMProvider {
  func complete(prompt: String) async throws -> String {
    throw LLMError.providerFailed("the provider is down")
  }
}

private struct EchoProvider: LLMProvider {
  func complete(prompt: String) async throws -> String { "narrated prose" }
}

private struct EmptyAnswerProvider: LLMProvider {
  func complete(prompt: String) async throws -> String { "" }
}
