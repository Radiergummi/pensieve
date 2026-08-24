import Foundation

/// Every loose-end quote any model surfaced during a sweep, per corpus item.
///
/// This exists because the gold set could not otherwise be completed. `CellScoring.goldScores` needs
/// `GoldSet.grounding` to hold BOTH grounded and fabricated quotes: precision is the fraction of a
/// model's surfaced quotes that are grounded, and `reproducedFabrication` fires when a model surfaces
/// a quote known to be fabricated. But `pensieve eval gold` only ever asked a human to *type quotes
/// they already knew about* — and nobody can type a fabrication in advance, because a fabrication is
/// by definition something a model invented. So the fabricated half of the gold set was unreachable,
/// which is why extraction precision and the fabrication gate have never had data to work with.
///
/// The quotes were already computed — `CellSample.looseEndQuotes` carries them — and then discarded
/// when the run ended, since only `scorecard.json` and `report.md` were written. Persisting them is
/// what turns "run a sweep" into "a sweep proposes the candidates that need labelling".
///
/// Deliberately a union across models, not per model: the question a label answers ("is this quote
/// grounded in the source?") is a property of the quote and the item, not of whichever model happened
/// to produce it. Two models surfacing the same fabrication is one thing to label, once.
public struct SurfacedQuotes: Codable, Sendable {
  /// itemID → every distinct quote surfaced for it, sorted for a stable on-disk diff.
  public var byItem: [String: [String]]

  public init(byItem: [String: [String]] = [:]) { self.byItem = byItem }

  /// Folds one run's samples in, preserving anything a previous run surfaced. Additive because a
  /// fabrication a model produced last week is still worth having labelled — a gold set that forgot
  /// it would let that regression back in silently.
  public mutating func merge(itemID: String, quotes: [String]) {
    var combined = Set(byItem[itemID] ?? [])
    combined.formUnion(quotes)
    byItem[itemID] = combined.sorted()
  }

  /// The quotes for `itemID` that carry no human label yet — the labelling queue.
  public func unlabelled(itemID: String, gold: GoldSet) -> [String] {
    let labelled = Set((gold.grounding[itemID] ?? []).map(\.quote))
    return (byItem[itemID] ?? []).filter { !labelled.contains($0) }
  }

  public static func load(from url: URL) -> SurfacedQuotes {
    guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode(SurfacedQuotes.self, from: data)
    else { return SurfacedQuotes() }
    return decoded
  }

  public func save(to url: URL) throws {
    try EvalPaths.ensureDirectory(url.deletingLastPathComponent())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url)
  }
}
