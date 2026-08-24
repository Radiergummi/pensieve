import Foundation

public struct NarrationTask: EvalTask {
  public init() {}
  public let id = "narration"
  public let scorer: ScorerKind = .rubric(dimensions: ["grounded", "complete", "concise", "noInventedFacts"])

  /// `narrate` returns nil for FOUR different reasons — no events, no narratable content, a provider
  /// throw, and an empty reply — and this task cannot tell them apart, because the prompt and the
  /// call both live inside `SummaryBuilder`. The provider throw is the one that must not be scored
  /// as bad prose, and it is detected where it actually happens: `Runner` hands the task a
  /// `MeasuredProvider`, which latches the throw at the seam and turns the sample's outcome into
  /// `providerError`. So the empty output below is only ever read as a real result when no provider
  /// call failed. Do not "fix" this by inferring the reason here — that would restate `narrate`'s
  /// rules in the eval layer, which is precisely the drift this codebase keeps paying for.
  public func run(item: CorpusItem, model: any LLMProvider, reference: any LLMProvider) async throws -> TaskOutput {
    guard case .narration(let narration) = item else { throw EvalTaskError(message: "narration task got non-narration item") }
    let node = Node(name: narration.nodeName)
    let events = narration.events.map { $0.toDomain() }
    let prose = await SummaryBuilder(provider: model).narrate(project: node, events: events)
    return TaskOutput(text: prose ?? "", looseEnds: nil)
  }
}
