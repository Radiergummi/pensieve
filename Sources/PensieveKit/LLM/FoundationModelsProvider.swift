import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels

/// Default provider: on-device Apple model. No API key, no rate limits, no subprocess.
///
/// Structured output uses **guided generation with a runtime-built `GenerationSchema`**
/// (not the `@Generable` macro). The framework constrains decoding to the schema, so the
/// ~3B on-device model returns valid structure instead of conversational prose — the fix
/// for the acceptance run's precision failure. The runtime schema is chosen deliberately
/// over the macro: the `@Generable`/`@Guide` macros compile under `swift build` but their
/// plugin fails to load in this machine's test build, and the runtime API needs no macro.
/// The verbatim gate still independently checks each quote — structure is guaranteed here,
/// truthfulness is not.
@available(macOS 26.0, *)
public struct FoundationModelsProvider: LLMProvider {
  public init() {}

  public func complete(prompt: String) async throws -> String {
    Log.llm.debug("LLM prompt dispatched (len=\(prompt.count, privacy: .public), provider=foundationModels)")
    let session = LanguageModelSession()
    do {
      let response = try await session.respond(to: prompt)
      Log.llm.debug("LLM completion received (len=\(response.content.count, privacy: .public))")
      return response.content
    } catch {
      Log.llm.error("FoundationModels complete failed: \(error, privacy: .public)")
      throw LLMError.providerFailed("FoundationModels: \(error)")
    }
  }

  public func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] {
    let session = LanguageModelSession()
    do {
      let content = try await session.respond(to: prompt, schema: Self.candidateListSchema()).content
      guard case .structure(let root, _) = content.kind,
            case .array(let items)? = root["candidates"]?.kind else { return [] }
      return items.compactMap { item in
        guard case .structure(let fields, _) = item.kind,
              case .string(let text)? = fields["text"]?.kind,
              case .string(let quote)? = fields["quote"]?.kind,
              case .number(let idx)? = fields["messageIndex"]?.kind else { return nil }
        return LooseEndCandidate(text: text, quote: quote, messageIndex: Int(idx))
      }
    } catch {
      // Preserve the wrapped description so the extractor's context-overflow re-split fires.
      Log.llm.error("FoundationModels extractCandidates failed: \(error, privacy: .public)")
      throw LLMError.providerFailed("FoundationModels: \(error)")
    }
  }

  public func classifyGenuineIndices(prompt: String) async throws -> [Int] {
    let session = LanguageModelSession()
    do {
      let content = try await session.respond(to: prompt, schema: Self.genuineIndicesSchema()).content
      guard case .structure(let root, _) = content.kind,
            case .array(let items)? = root["indices"]?.kind else { return [] }
      return items.compactMap { if case .number(let numberValue) = $0.kind { return Int(numberValue) } else { return nil } }
    } catch {
      Log.llm.error("FoundationModels classifyGenuineIndices failed: \(error, privacy: .public)")
      throw LLMError.providerFailed("FoundationModels: \(error)")
    }
  }

  public func classifyNonSalientIndices(prompt: String) async throws -> [Int] {
    let session = LanguageModelSession()
    do {
      let content = try await session.respond(to: prompt, schema: Self.nonSalientIndicesSchema()).content
      guard case .structure(let root, _) = content.kind,
            case .array(let items)? = root["indices"]?.kind else { return [] }
      return items.compactMap { if case .number(let numberValue) = $0.kind { return Int(numberValue) } else { return nil } }
    } catch {
      Log.llm.error("FoundationModels classifyNonSalientIndices failed: \(error, privacy: .public)")
      throw LLMError.providerFailed("FoundationModels: \(error)")
    }
  }

  /// `{ candidates: [{ text, quote, messageIndex }] }`. Built per call (cheap next to model
  /// inference) so there's no shared static and construction errors surface as thrown, not traps.
  private static func candidateListSchema() throws -> GenerationSchema {
    let candidate = DynamicGenerationSchema(name: "LooseEnd", properties: [
      .init(name: "text",
            description: "A short paraphrase of the loose end, in the developer's own words",
            schema: DynamicGenerationSchema(type: String.self)),
      .init(name: "quote",
            description: "A substring copied character-for-character (verbatim, same casing) from exactly one message",
            schema: DynamicGenerationSchema(type: String.self)),
      .init(name: "messageIndex",
            description: "The [n] index of the message the quote was copied from",
            schema: DynamicGenerationSchema(type: Int.self)),
    ])
    let root = DynamicGenerationSchema(name: "LooseEndList", properties: [
      .init(name: "candidates",
            description: "Every loose end found in the messages; empty when there are none",
            schema: DynamicGenerationSchema(arrayOf: candidate)),
    ])
    return try GenerationSchema(root: root, dependencies: [])
  }

  /// `{ indices: [Int] }`.
  private static func genuineIndicesSchema() throws -> GenerationSchema {
    let root = DynamicGenerationSchema(name: "GenuineIndices", properties: [
      .init(name: "indices",
            description: "The [n] indices of messages that are the developer's OWN conversational intent " +
              "(a request, question, decision, or note); empty when none qualify",
            schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: Int.self))),
    ])
    return try GenerationSchema(root: root, dependencies: [])
  }

  /// `{ indices: [Int] }` — the DROP set for salience.
  private static func nonSalientIndicesSchema() throws -> GenerationSchema {
    let root = DynamicGenerationSchema(name: "NonSalientIndices", properties: [
      .init(name: "indices",
            description: "The [n] indices of items that are clearly in-the-moment requests the assistant simply " +
              "carried out — NOT deferred/parked/decision work left open. These will be dropped. Empty when every " +
              "item is a genuine loose end; when unsure about an item, do NOT include it.",
            schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: Int.self))),
    ])
    return try GenerationSchema(root: root, dependencies: [])
  }
}
#endif
