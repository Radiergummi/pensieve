import Foundation

public struct CandidateLabel: Codable, Sendable, Equatable {
  public var quote: String; public var grounded: Bool
  public init(quote: String, grounded: Bool) { self.quote = quote; self.grounded = grounded }
}

public struct JudgeVerdict: Codable, Sendable, Equatable {
  public var quality: Double?
  public var dimensionScores: [String: Double]?
  public var candidateLabels: [CandidateLabel]?
}

public enum JudgeDecode {
  /// Extract the first balanced JSON object/array substring and decode it (tolerates ``` fences + prose).
  public static func object<T: Decodable>(_ raw: String, as type: T.Type) -> T? {
    guard let start = raw.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
    let open = raw[start], close: Character = (open == "{") ? "}" : "]"
    var depth = 0, end: String.Index? = nil
    var i = start
    while i < raw.endIndex {
      if raw[i] == open { depth += 1 } else if raw[i] == close { depth -= 1; if depth == 0 { end = i; break } }
      i = raw.index(after: i)
    }
    guard let e = end else { return nil }
    let slice = String(raw[start...e])
    return try? JSONDecoder().decode(T.self, from: Data(slice.utf8))
  }
}

public struct Judge: Sendable {
  private let provider: any LLMProvider
  public init(provider: any LLMProvider) { self.provider = provider }

  // Blinded: no model identity in any prompt.
  public func scoreRubric(output: String, dimensions: [String], sourceContext: String) async -> JudgeVerdict? {
    let dims = dimensions.joined(separator: ", ")
    let prompt = """
    You are grading a generated text against its source. Score each dimension in [0,1].
    Dimensions: \(dims).
    Return ONLY JSON: {"dimensionScores": {"<dim>": <0..1>, ...}, "quality": <mean 0..1>}.

    SOURCE:
    \(sourceContext)

    GENERATED:
    \(output)
    """
    guard let raw = try? await provider.complete(prompt: prompt) else { return nil }
    return JudgeDecode.object(raw, as: JudgeVerdict.self)
  }

  public func labelGrounding(looseEnds: [VerifiedLooseEnd], source: String) async -> [CandidateLabel]? {
    guard !looseEnds.isEmpty else { return [] }
    let quotes = looseEnds.enumerated().map { "\($0.offset). «\($0.element.quote)»" }.joined(separator: "\n")
    let prompt = """
    For each candidate quote, decide if it is genuinely grounded in the SOURCE (true) or fabricated / not supported (false).
    Return ONLY JSON: {"candidateLabels": [{"quote": "<verbatim quote>", "grounded": true|false}, ...]}.

    SOURCE:
    \(source)

    CANDIDATES:
    \(quotes)
    """
    guard let raw = try? await provider.complete(prompt: prompt) else { return nil }
    return JudgeDecode.object(raw, as: JudgeVerdict.self)?.candidateLabels
  }
}
