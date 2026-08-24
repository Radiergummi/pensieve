import Foundation
import os

/// Wraps the provider one cell runs against, so the harness can observe two things a task's return
/// value cannot distinguish:
///
/// 1. **How much prompt text actually reached the model.** A task builds its prompts *inside* the
///    production code path it measures (`SummaryBuilder.narrate` owns and never exposes its own), so
///    the only place the input side of the cost axis is visible is the seam every call crosses.
///    `Runner` wrote `estInputTokens: 0` before this existed, so a long-prompt model looked free.
/// 2. **Whether the provider itself failed.** `SummaryBuilder.narrate` folds a provider throw into
///    "nothing to narrate" and returns nil, so a dead provider reached `CellScoring` as a
///    *successful* empty output — scored as a bad model rather than a failed run, which is exactly
///    the protection `CellScoring` documents at its top.
///
/// All four protocol methods are forwarded explicitly rather than inheriting the extension
/// defaults: the on-device provider OVERRIDES the three structured methods with guided generation,
/// and a wrapper that fell through to the JSON-prompt defaults would measure a pipeline that is not
/// the one shipped.
///
/// Only the *measured* model is wrapped, never `reference`: the reference provider's prompts (the
/// pinned intent classifier) belong to the reference's cost, and its failure is a fail-open the
/// production pipeline is designed for, not a failure of the cell.
final class MeasuredProvider: LLMProvider, @unchecked Sendable {
  private struct Measurement {
    var estInputTokens = 0
    var providerFailed = false
  }

  private let wrapped: any LLMProvider
  private let state = OSAllocatedUnfairLock(initialState: Measurement())

  init(_ wrapped: any LLMProvider) { self.wrapped = wrapped }

  /// Estimated input tokens summed over every call this cell made, and whether any call threw.
  var estInputTokens: Int { state.withLock { $0.estInputTokens } }
  var providerFailed: Bool { state.withLock { $0.providerFailed } }

  func complete(prompt: String) async throws -> String {
    try await record(prompt) { try await wrapped.complete(prompt: prompt) }
  }

  func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] {
    try await record(prompt) { try await wrapped.extractCandidates(prompt: prompt) }
  }

  func classifyGenuineIndices(prompt: String) async throws -> [Int] {
    try await record(prompt) { try await wrapped.classifyGenuineIndices(prompt: prompt) }
  }

  func classifyNonSalientIndices(prompt: String) async throws -> [Int] {
    try await record(prompt) { try await wrapped.classifyNonSalientIndices(prompt: prompt) }
  }

  /// Counts the prompt BEFORE the call, so an input that was paid for and then failed still shows up
  /// on the cost axis, and latches the failure flag on the way out.
  private func record<Result>(_ prompt: String,
                              _ call: () async throws -> Result) async throws -> Result {
    state.withLock { $0.estInputTokens += TokenEstimate.tokens(prompt) }
    do {
      return try await call()
    } catch {
      state.withLock { $0.providerFailed = true }
      throw error
    }
  }
}
