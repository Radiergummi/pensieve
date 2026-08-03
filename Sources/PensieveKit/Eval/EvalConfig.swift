import Foundation

public struct ModelSpec: Codable, Sendable, Equatable {
  public var label: String
  public var kind: String            // "foundationModels" | "cloud"
  public var flavor: CloudFlavor?
  public var baseURL: String?
  public var model: String?
  public var inputPricePerM: Double
  public var outputPricePerM: Double
  public var isOnDevice: Bool { kind == "foundationModels" }

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
