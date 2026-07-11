import Foundation

public struct EvalTaskError: Error, Sendable { public let message: String }

/// Stage-isolated extraction eval: the intent classifier is pinned to `reference` (a known-
/// good provider) so this task measures only the extraction stage's quality under `model`,
/// not the classifier's. The deterministic `LooseEndVerifier` still gates every output —
/// the trust gate is never bypassed for eval purposes.
public struct ExtractionTask: EvalTask {
  public init() {}
  public let id = "extraction"
  public let scorer: ScorerKind = .extraction

  public func run(item: CorpusItem, model: any LLMProvider, reference: any LLMProvider) async throws -> TaskOutput {
    guard case .extraction(let ext) = item else { throw EvalTaskError(message: "extraction task got non-extraction item") }
    let messages = ext.messages.map { $0.toDomain() }
    // Stage-isolation: classifier pinned to `reference`, extraction swapped to `model`.
    let candidates = try await LooseEndExtractor(provider: model, classifierProvider: reference).extract(from: messages)
    let verified = candidates.compactMap { LooseEndVerifier.verify($0, messages: messages) }
    let text = verified.map { "- \($0.text)  «\($0.quote)»" }.joined(separator: "\n")
    return TaskOutput(text: text, looseEnds: verified)
  }
}
