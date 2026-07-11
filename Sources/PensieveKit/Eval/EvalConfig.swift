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

  public static func load(from url: URL) throws -> EvalConfig {
    try JSONDecoder().decode(EvalConfig.self, from: Data(contentsOf: url))
  }
  public func bar(for task: String) -> TaskBar? { bars.first { $0.task == task } }
  public func spec(label: String) -> ModelSpec? { roster.first { $0.label == label } }
}
