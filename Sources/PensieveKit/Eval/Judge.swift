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
  /// String-aware: braces/brackets inside JSON string values (and escaped quotes) don't affect the depth count.
  public static func object<T: Decodable>(_ raw: String, as type: T.Type) -> T? {
    guard let start = raw.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
    let open = raw[start], close: Character = (open == "{") ? "}" : "]"
    var depth = 0, end: String.Index?
    var inString = false, escaped = false
    var currentIndex = start
    while currentIndex < raw.endIndex {
      let character = raw[currentIndex]
      if inString {
        consumeStringCharacter(character, escaped: &escaped, inString: &inString)
      } else if consumeStructuralCharacter(character, open: open, close: close, depth: &depth, inString: &inString) {
        end = currentIndex
        break
      }
      currentIndex = raw.index(after: currentIndex)
    }
    guard let endIndex = end else { return nil }
    let slice = String(raw[start...endIndex])
    return try? JSONDecoder().decode(T.self, from: Data(slice.utf8))
  }

  /// Tracks escape/quote state for a character known to be inside a JSON string literal.
  private static func consumeStringCharacter(_ character: Character, escaped: inout Bool, inString: inout Bool) {
    if escaped {
      escaped = false
    } else if character == "\\" {
      escaped = true
    } else if character == "\"" {
      inString = false
    }
  }

  /// Tracks bracket depth for a character known to be outside a JSON string literal.
  /// Returns true when this character closes the top-level object/array (`depth` reaches 0).
  private static func consumeStructuralCharacter(
    _ character: Character, open: Character, close: Character, depth: inout Int, inString: inout Bool
  ) -> Bool {
    if character == "\"" {
      inString = true
    } else if character == open {
      depth += 1
    } else if character == close {
      depth -= 1
      if depth == 0 { return true }
    }
    return false
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

  /// Takes quotes, not `VerifiedLooseEnd`s: the only field it ever read was `quote`, and demanding
  /// the full type forced callers to fabricate `text`/`role`/`sourceMessageIndex` values that the
  /// prompt never sees — inventing structure to satisfy a signature. The gold-labelling flow feeds
  /// it raw strings, which is what a quote is.
  public func labelGrounding(quotes candidates: [String], source: String) async -> [CandidateLabel]? {
    guard !candidates.isEmpty else { return [] }
    let quotes = candidates.enumerated().map { "\($0.offset). «\($0.element)»" }.joined(separator: "\n")
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
