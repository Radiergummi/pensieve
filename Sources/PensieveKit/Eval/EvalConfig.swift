import Foundation

public struct ModelSpec: Codable, Sendable, Equatable {
  /// The three providers a roster can name. Kept as raw `String` on the wire (not a `Codable` enum)
  /// so an unrecognised `kind` in `eval-config.json` degrades to "cannot build this model, skip the
  /// spec" instead of failing the whole decode and taking the sweep down with it.
  public static let foundationModelsKind = "foundationModels"
  public static let cloudKind = "cloud"
  /// `claude -p` through the Claude *subscription* — no API key. This machine has a subscription and
  /// no key, and the project rule is that a new LLM-backed task takes its default model from
  /// `pensieve eval`, so the provider that actually exists here has to be nameable in a roster.
  public static let claudeCLIKind = "claudeCLI"

  public var label: String
  public var kind: String            // one of the three `*Kind` constants above
  public var flavor: CloudFlavor?
  public var baseURL: String?
  public var model: String?
  public var inputPricePerM: Double
  public var outputPricePerM: Double
  /// `claudeCLI` is deliberately NOT on-device: it is a local *process*, but the inference happens
  /// in the cloud. `isOnDevice` drives `DecisionEngine`'s local-first ranking, which is a privacy
  /// and offline-availability claim, not a "costs nothing" claim.
  public var isOnDevice: Bool { kind == Self.foundationModelsKind }

  // Explicit (Swift only synthesizes an *internal* memberwise init for a public struct) so callers
  // outside PensieveKit can build a spec in code instead of decoding a JSON literal.
  public init(label: String, kind: String, flavor: CloudFlavor? = nil, baseURL: String? = nil,
              model: String? = nil, inputPricePerM: Double, outputPricePerM: Double) {
    self.label = label
    self.kind = kind
    self.flavor = flavor
    self.baseURL = baseURL
    self.model = model
    self.inputPricePerM = inputPricePerM
    self.outputPricePerM = outputPricePerM
  }
}

public struct TaskBar: Codable, Sendable, Equatable {
  public var task: String
  public var inheritFromIncumbent: Bool
  public var precision: Double?
  public var recall: Double?
  public var quality: Double?
}

public struct EvalConfig: Codable, Sendable, Equatable {
  public var roster: [ModelSpec]
  public var referenceProvider: String
  public var judge: ModelSpec
  public var bars: [TaskBar]
  public var corpusSize: Int
  public var corpusSeed: UInt64
  public var noiseMargin: Double

  // Explicit for the same reason as `ModelSpec.init` above — it lets the CLI build its fallback
  // config in code, so adding a field here is a compile error rather than a runtime decode crash.
  public init(roster: [ModelSpec], referenceProvider: String, judge: ModelSpec, bars: [TaskBar],
              corpusSize: Int, corpusSeed: UInt64, noiseMargin: Double) {
    self.roster = roster
    self.referenceProvider = referenceProvider
    self.judge = judge
    self.bars = bars
    self.corpusSize = corpusSize
    self.corpusSeed = corpusSeed
    self.noiseMargin = noiseMargin
  }

  public static func load(from url: URL) throws -> EvalConfig {
    try JSONDecoder().decode(EvalConfig.self, from: Data(contentsOf: url))
  }
  public func bar(for task: String) -> TaskBar? { bars.first { $0.task == task } }
  public func spec(label: String) -> ModelSpec? { roster.first { $0.label == label } }
}
