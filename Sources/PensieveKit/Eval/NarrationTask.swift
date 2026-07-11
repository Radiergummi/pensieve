import Foundation

public struct NarrationTask: EvalTask {
  public init() {}
  public let id = "narration"
  public let scorer: ScorerKind = .rubric(dimensions: ["grounded", "complete", "concise", "noInventedFacts"])

  public func run(item: CorpusItem, model: any LLMProvider, reference: any LLMProvider) async throws -> TaskOutput {
    guard case .narration(let n) = item else { throw EvalTaskError(message: "narration task got non-narration item") }
    let node = Node(name: n.nodeName)
    let events = n.events.map { $0.toDomain() }
    let prose = await SummaryBuilder(provider: model).narrate(project: node, events: events)
    return TaskOutput(text: prose ?? "", looseEnds: nil)
  }
}
