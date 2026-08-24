import Foundation

public struct GoldSet: Codable, Sendable {
  public var recall: [String: [String]]              // itemID → known loose-end quotes
  public var grounding: [String: [CandidateLabel]]   // itemID → human grounded/fabricated labels
  public init(recall: [String: [String]], grounding: [String: [CandidateLabel]]) {
    self.recall = recall; self.grounding = grounding
  }
  public static func load(from url: URL) -> GoldSet {
    guard let data = try? Data(contentsOf: url),
          let goldSet = try? JSONDecoder().decode(GoldSet.self, from: data) else { return GoldSet(recall: [:], grounding: [:]) }
    return goldSet
  }
  public func save(to url: URL) throws {
    try EvalPaths.ensureDirectory(url.deletingLastPathComponent())
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(self).write(to: url)
  }
  /// Fraction of known quotes that were surfaced (verbatim). nil if this item has no gold entry.
  public func recallScore(itemID: String, surfaced: [String]) -> Double? {
    guard let known = recall[itemID], !known.isEmpty else { return nil }
    let hit = known.filter { surfaced.contains($0) }.count
    return Double(hit) / Double(known.count)
  }
}
