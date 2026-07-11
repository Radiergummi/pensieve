import Foundation

public enum LLMError: Error, Sendable { case providerFailed(String) }

/// The single narrow seam through which all model calls flow. `complete` is prompt in /
/// text out (used for narration). The two structured methods return decoded values: a
/// provider that can guarantee structure (Foundation Models via guided generation) does so
/// natively; every other provider inherits a default that prompts for JSON and decodes it,
/// so any provider (local or HTTP) satisfies the protocol with only `complete`.
/// Any new task that calls a model through this seam should be evaluated by the harness —
/// register an `EvalTask` and let `pensieve eval` choose its default (on-device-first),
/// don't hand-pick a model. See `Sources/PensieveKit/Eval/README.md`.
public protocol LLMProvider: Sendable {
  func complete(prompt: String) async throws -> String

  /// Loose-end candidates for the given extraction prompt. The default decodes JSON from
  /// `complete`; the on-device provider overrides it with guided generation so the ~3B
  /// model emits valid structure instead of answering conversationally.
  func extractCandidates(prompt: String) async throws -> [LooseEndCandidate]

  /// The `[n]` indices judged genuine developer intent for the given classification prompt.
  /// The default decodes JSON from `complete` and **throws** when the response is not a
  /// parseable index array (so the caller can fail open); the on-device provider overrides
  /// it with guided generation, which returns a real (possibly empty) array.
  func classifyGenuineIndices(prompt: String) async throws -> [Int]

  /// The `[n]` indices judged NOT loose ends (in-the-moment requests) for the given salience
  /// prompt — the DROP set. The default decodes JSON from `complete` and **throws** when the
  /// response is not a parseable index array (so the caller fails open → keeps all); the
  /// on-device provider overrides it with guided generation returning a real (possibly empty)
  /// array. An empty array means "drop nothing" (keep all) — the safe, keep-on-low-confidence default.
  func classifyNonSalientIndices(prompt: String) async throws -> [Int]
}

public extension LLMProvider {
  func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] {
    LooseEndExtractor.decodeCandidates(try await complete(prompt: prompt))
  }

  func classifyGenuineIndices(prompt: String) async throws -> [Int] {
    guard let indices = IntentClassifier.decodeIndices(try await complete(prompt: prompt)) else {
      throw LLMError.providerFailed("classifier response was not a parseable index array")
    }
    return Array(indices)
  }

  func classifyNonSalientIndices(prompt: String) async throws -> [Int] {
    guard let indices = IntentClassifier.decodeIndices(try await complete(prompt: prompt)) else {
      throw LLMError.providerFailed("salience response was not a parseable index array")
    }
    return Array(indices)
  }
}
