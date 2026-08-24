import Foundation

public struct GoldSet: Codable, Sendable {
  public var recall: [String: [String]]              // itemID → known loose-end quotes
  public var grounding: [String: [CandidateLabel]]   // itemID → human grounded/fabricated labels
  /// itemID → what the JUDGE said about the same quotes, kept beside the human's answer.
  ///
  /// Stored rather than reduced to an agreement percentage, because the percentage is the thing you
  /// would want to re-derive later: over a subset, per item shape, after a judge-model change. A
  /// stored number answers one question forever; the labels answer the questions you have not asked
  /// yet, and `Agreement.rate` recomputes the number from them whenever it is wanted.
  ///
  /// Only ever written where a human answered too. A judge label with no human counterpart would
  /// quietly become ground truth for `CellScoring.goldScores`, which is the one thing this must not
  /// do — the gold set is what the judge is measured AGAINST.
  public var judgeGrounding: [String: [CandidateLabel]]

  public init(recall: [String: [String]], grounding: [String: [CandidateLabel]],
              judgeGrounding: [String: [CandidateLabel]] = [:]) {
    self.recall = recall; self.grounding = grounding; self.judgeGrounding = judgeGrounding
  }

  /// Decodes a gold set written before `judgeGrounding` existed — those files simply have no judge
  /// labels, which is exactly what an empty dictionary means.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    recall = try container.decode([String: [String]].self, forKey: .recall)
    grounding = try container.decode([String: [CandidateLabel]].self, forKey: .grounding)
    judgeGrounding = try container.decodeIfPresent([String: [CandidateLabel]].self,
                                                   forKey: .judgeGrounding) ?? [:]
  }

  /// Judge-vs-human agreement across every item where both answered the same quote, or nil when
  /// they never have. This is the number that says whether the judge could be trusted to label the
  /// rest of a corpus without a human — and it is earned, not asserted: every datapoint in it came
  /// from a human either confirming or correcting a judge label they were shown.
  /// Computed per item and then pooled, never by flattening both sides first: `Agreement.rate` keys
  /// on quote TEXT, so a flattened comparison would let the same sentence appearing in two different
  /// items collide — and `uniquingKeysWith` would silently keep one item's verdict for the other's.
  /// Pooling by shared-quote count rather than averaging per-item rates also keeps a 20-quote item
  /// from counting the same as a 1-quote one.
  public func judgeAgreement() -> Double? {
    var matches = 0
    var total = 0
    for (itemID, humanLabels) in grounding {
      guard let judgeLabels = judgeGrounding[itemID] else { continue }
      let judgeByQuote = Dictionary(judgeLabels.map { ($0.quote, $0.grounded) },
                                    uniquingKeysWith: { existing, _ in existing })
      for humanLabel in humanLabels {
        guard let judged = judgeByQuote[humanLabel.quote] else { continue }
        total += 1
        if judged == humanLabel.grounded { matches += 1 }
      }
    }
    return total == 0 ? nil : Double(matches) / Double(total)
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
