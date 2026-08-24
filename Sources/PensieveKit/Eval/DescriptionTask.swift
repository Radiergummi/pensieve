import Foundation

public struct DescriptionTask: EvalTask {
  public init() {}
  public let id = "description"
  public let scorer: ScorerKind = .rubric(dimensions: ["accurate", "specific"])

  public func run(item: CorpusItem, model: any LLMProvider, reference: any LLMProvider) async throws -> TaskOutput {
    guard case .description(let description) = item else { throw EvalTaskError(message: "description task got non-description item") }
    let context = description.context.toDomain()
    let prompt = ProjectContext.describePrompt(context)
    // `try`, not `try?`: a provider failure is a FAILED RUN, and swallowing it here handed
    // `CellScoring` a successful empty output — a dead provider scored as a bad model. A rejected
    // (nil `sanitize`) output stays "" and successful, because that IS a model-quality result.
    let raw = try await model.complete(prompt: prompt)
    let cleaned = NodeDescriber.sanitize(raw) ?? ""
    return TaskOutput(text: cleaned, looseEnds: nil)
  }
}
