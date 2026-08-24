// Sources/PensieveKit/Eval/Runner.swift
import Foundation

public enum RunOutcome {
  /// `providerFailed` covers the case the task's own return value cannot report: a provider call
  /// threw somewhere inside the production path and that path folded it into an empty result
  /// (`SummaryBuilder.narrate` returns nil for a throw exactly as it does for "nothing to narrate").
  /// Without it a dead provider arrived here as `"success"` with empty output, which `CellScoring`
  /// then scored as a bad model instead of excluding as a failed run.
  public static func classify(_ error: Error?, providerFailed: Bool = false) -> String {
    guard let error else { return providerFailed ? "providerError" : "success" }
    if case LLMError.providerFailed(let message) = error,
       message.localizedCaseInsensitiveContains("parseable")
         || message.localizedCaseInsensitiveContains("parse")
         || message.localizedCaseInsensitiveContains("json") {
      return "parseFail"
    }
    return "providerError"
  }
}

public struct CellSample: Sendable, Codable {
  public var task: String; public var modelLabel: String; public var itemID: String
  public var outputText: String; public var looseEndQuotes: [String]?
  public var latencyMS: Double; public var estInputTokens: Int; public var estOutputTokens: Int; public var outcome: String
}

public struct Runner {
  private let config: EvalConfig
  private let keychain: KeychainSecretStore
  public init(config: EvalConfig, keychain: KeychainSecretStore = KeychainSecretStore()) {
    self.config = config; self.keychain = keychain
  }

  /// Runs one (task, item, model) cell `repeats` times. Skips (returns []) if the model can't be built (missing key / unavailable).
  ///
  /// The reference provider gets the key its OWN spec needs, rather than a hardcoded nil: the
  /// reference can be any roster entry, and passing nil made a key-requiring reference fail to build
  /// and the whole cell return `[]` with nothing said about why.
  public func runCell(task: any EvalTask, item: CorpusItem, spec: ModelSpec, repeats: Int) async -> [CellSample] {
    guard let model = ModelProviderFactory.make(spec, apiKey: key(for: spec)) else { return [] }
    guard let referenceSpec = config.spec(label: config.referenceProvider),
          let reference = ModelProviderFactory.make(referenceSpec, apiKey: key(for: referenceSpec))
    else { return [] }

    var samples: [CellSample] = []
    let clock = ContinuousClock()
    for _ in 0..<max(1, repeats) {
      var output = TaskOutput(text: "", looseEnds: nil)
      var caughtError: Error?
      // One wrapper per repeat, so the cost axis and the failure flag describe THIS sample.
      let measured = MeasuredProvider(model)
      let elapsed = await measure(clock) {
        do {
          output = try await task.run(item: item, model: measured, reference: reference)
        } catch {
          caughtError = error
        }
      }
      samples.append(CellSample(
        task: task.id, modelLabel: spec.label, itemID: item.id,
        outputText: output.text, looseEndQuotes: output.looseEnds?.map { $0.quote },
        latencyMS: elapsed, estInputTokens: measured.estInputTokens,
        estOutputTokens: TokenEstimate.tokens(output.text),
        outcome: RunOutcome.classify(caughtError, providerFailed: measured.providerFailed)))
    }
    return samples
  }

  private func key(for spec: ModelSpec) -> String? {
    guard ModelProviderFactory.needsKey(spec) else { return nil }
    return keychain.read(account: ModelProviderFactory.apiKeyAccount(for: spec))
  }

  private func measure(_ clock: ContinuousClock, _ body: () async -> Void) async -> Double {
    let start = clock.now
    await body()
    let durationComponents = start.duration(to: clock.now).components            // (seconds, attoseconds)
    return Double(durationComponents.seconds) * 1000 + Double(durationComponents.attoseconds) / 1e15   // → ms (seconds included!)
  }
}
