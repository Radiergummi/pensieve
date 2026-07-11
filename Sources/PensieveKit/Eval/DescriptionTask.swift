import Foundation

public struct DescriptionTask: EvalTask {
  public init() {}
  public let id = "description"
  public let scorer: ScorerKind = .rubric(dimensions: ["accurate", "specific"])

  public func run(item: CorpusItem, model: any LLMProvider, reference: any LLMProvider) async throws -> TaskOutput {
    guard case .description(let d) = item else { throw EvalTaskError(message: "description task got non-description item") }
    let ctx = d.context.toDomain()
    let prompt = ProjectContext.describePrompt(ctx)
    let raw = (try? await model.complete(prompt: prompt)) ?? ""
    let cleaned = NodeDescriber.sanitize(raw) ?? ""
    return TaskOutput(text: cleaned, looseEnds: nil)
  }
}
