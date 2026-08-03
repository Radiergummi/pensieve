// Sources/PensieveKit/Eval/Runner.swift
import Foundation

public enum RunOutcome {
  public static func classify(_ error: Error?) -> String {
    guard let error else { return "success" }
    if case LLMError.providerFailed(let msg) = error,
       msg.localizedCaseInsensitiveContains("parseable") || msg.localizedCaseInsensitiveContains("parse")
         || msg.localizedCaseInsensitiveContains("json") {
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
  public func runCell(task: any EvalTask, item: CorpusItem, spec: ModelSpec, repeats: Int) async -> [CellSample] {
    let apiKey = ModelProviderFactory.needsKey(spec) ? keychain.read(account: ModelProviderFactory.apiKeyAccount(for: spec)) : nil
    guard let model = ModelProviderFactory.make(spec, apiKey: apiKey) else { return [] }
    guard let refSpec = config.spec(label: config.referenceProvider),
          let reference = ModelProviderFactory.make(refSpec, apiKey: nil) else { return [] }

    var samples: [CellSample] = []
    let clock = ContinuousClock()
    for _ in 0..<max(1, repeats) {
      var output = TaskOutput(text: "", looseEnds: nil)
      var err: Error?
      let elapsed = await measure(clock) {
        do { output = try await task.run(item: item, model: model, reference: reference) } catch { err = error }
      }
      samples.append(CellSample(
        task: task.id, modelLabel: spec.label, itemID: item.id,
        outputText: output.text, looseEndQuotes: output.looseEnds?.map { $0.quote },
        latencyMS: elapsed, estInputTokens: 0, estOutputTokens: TokenEstimate.tokens(output.text),
        outcome: RunOutcome.classify(err)))
    }
    return samples
  }

  private func measure(_ clock: ContinuousClock, _ body: () async -> Void) async -> Double {
    let start = clock.now
    await body()
    let durationComponents = start.duration(to: clock.now).components            // (seconds, attoseconds)
    return Double(durationComponents.seconds) * 1000 + Double(durationComponents.attoseconds) / 1e15   // → ms (seconds included!)
  }
}
