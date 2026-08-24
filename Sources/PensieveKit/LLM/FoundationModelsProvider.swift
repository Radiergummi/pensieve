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

  /// Wall-clock cap on a single on-device call, the same 120 s `ClaudeCLIProvider` gives `claude -p`
  /// and for the same reason: an unbounded `session.respond` has no cap of its own, and a stall
  /// (model asset reload, resource pressure) parks the caller forever. That is how the background
  /// sync agent hung — launchd will not start a second instance while one is still running, so a
  /// single stalled respond stopped background sync until logout, with a frozen log as the only
  /// evidence. A timeout turns "silent forever" into a logged error and a retry next pass.
  static let timeout: TimeInterval = 120

  /// Races `work` against `timeout`. On timeout the group's exit cancels the model task, which is
  /// how the stalled `respond` is actually abandoned rather than merely ignored.
  private static func within<Value: Sendable>(
    _ label: String, _ work: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask { try await work() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        Log.llm.error("FoundationModels \(label, privacy: .public) timed out after \(Int(timeout), privacy: .public)s")
        throw LLMError.providerFailed("FoundationModels \(label) timed out after \(Int(timeout))s")
      }
      guard let first = try await group.next() else {
        throw LLMError.providerFailed("FoundationModels \(label) produced no result")
      }
      group.cancelAll()
      return first
    }
  }

  public func complete(prompt: String) async throws -> String {
    Log.llm.debug("LLM prompt dispatched (len=\(prompt.count, privacy: .public), provider=foundationModels)")
    do {
      let content = try await Self.within("complete") {
        try await LanguageModelSession().respond(to: prompt).content
      }
      Log.llm.debug("LLM completion received (len=\(content.count, privacy: .public))")
      return content
    } catch {
      Log.llm.error("FoundationModels complete failed: \(error, privacy: .public)")
      throw LLMError.providerFailed("FoundationModels: \(error)")
    }
  }

  public func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] {
    do {
      let content = try await Self.within("extractCandidates") {
        try await LanguageModelSession().respond(to: prompt, schema: Self.candidateListSchema()).content
      }
      // A structure mismatch means guided generation did not answer the question — NOT that there
      // are no loose ends. Reporting it as an empty array let `ExtractionRunner` advance its
      // watermark over a slice nothing had mined, retiring those messages for good.
      guard case .structure(let root, _) = content.kind,
            case .array(let items)? = root["candidates"]?.kind else {
        throw LLMError.providerFailed("guided generation returned no candidates array")
      }
      return items.compactMap { item in
        guard case .structure(let fields, _) = item.kind,
              case .string(let text)? = fields["text"]?.kind,
              case .string(let quote)? = fields["quote"]?.kind,
              case .number(let messageIndex)? = fields["messageIndex"]?.kind else { return nil }
        return LooseEndCandidate(text: text, quote: quote, messageIndex: Int(messageIndex))
      }
    } catch {
      // Preserve the wrapped description so the extractor's context-overflow re-split fires.
      Log.llm.error("FoundationModels extractCandidates failed: \(error, privacy: .public)")
      throw LLMError.providerFailed("FoundationModels: \(error)")
    }
  }

  public func classifyGenuineIndices(prompt: String) async throws -> [Int] {
    do {
      let content = try await Self.within("classifyGenuineIndices") {
        try await LanguageModelSession().respond(to: prompt, schema: Self.genuineIndicesSchema()).content
      }
      // Same rule as `extractCandidates`: a structure mismatch means guided generation did not
      // answer, which is NOT the same as "none of these prompts are genuine". The distinction is
      // load-bearing here in the worst way — `IntentClassifier.filterGenuine` trusts a structured
      // empty set as "drop this whole batch" (deliberately, and its tests pin it), and fails open
      // only on a throw. So returning [] here silently discarded EVERY user prompt in the batch,
      // yielding zero extraction candidates while the watermark advanced: the same permanent loss
      // as the extraction bug, one stage earlier. Throwing routes it to the documented fail-open
      // branch, which keeps all prompts.
      guard case .structure(let root, _) = content.kind,
            case .array(let items)? = root["indices"]?.kind else {
        throw LLMError.providerFailed("guided generation returned no indices array")
      }
      return items.compactMap { if case .number(let numberValue) = $0.kind { return Int(numberValue) } else { return nil } }
    } catch {
      Log.llm.error("FoundationModels classifyGenuineIndices failed: \(error, privacy: .public)")
      throw LLMError.providerFailed("FoundationModels: \(error)")
    }
  }

  public func classifyNonSalientIndices(prompt: String) async throws -> [Int] {
    do {
      let content = try await Self.within("classifyNonSalientIndices") {
        try await LanguageModelSession().respond(to: prompt, schema: Self.nonSalientIndicesSchema()).content
      }
      // One rule across all three guided-generation decoders. An empty drop-set is safe here
      // (`SalienceClassifier` reads it as "keep everything"), so this half was never losing data —
      // but a mismatch still is not an answer, and leaving two of the three decoders swallowing it
      // is how the next caller inherits the bug above.
      guard case .structure(let root, _) = content.kind,
            case .array(let items)? = root["indices"]?.kind else {
        throw LLMError.providerFailed("guided generation returned no indices array")
      }
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
            description: "The [n] indices of items that are NOT loose ends. A loose end is " +
              LooseEndDefinition.isDeferredWork + ". These will be dropped. Empty when every " +
              "item is a genuine loose end; when unsure about an item, do NOT include it.",
            schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: Int.self))),
    ])
    return try GenerationSchema(root: root, dependencies: [])
  }
}
#endif
