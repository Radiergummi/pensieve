// Sources/PensieveKit/Eval/CellScoring.swift
import Foundation

/// The two graders a cell is scored against: the frozen `GoldSet` (extraction) and the rubric
/// `Judge` (narration/description). Constant across a whole sweep, so they travel as one value.
///
/// `judge` is OPTIONAL because the two graders have independent availability: the gold set is a
/// committed file, while the judge is a cloud model that needs an API key this machine may not have.
/// A sweep with no judge still scores every gold-scored task; `pensieve eval run` skips the
/// judge-scored ones loudly rather than aborting the whole run.
public struct ScoringReferences {
  public var gold: GoldSet
  public var judge: Judge?
  public init(gold: GoldSet, judge: Judge?) {
    self.gold = gold
    self.judge = judge
  }
}

/// Reduces one model's raw run samples into a `CellScore`. Lives in PensieveKit (not the CLI)
/// so it's unit-testable.
public enum CellScoring {
  public static func taskID(for item: CorpusItem) -> String {
    switch item {
    case .extraction: return "extraction"
    case .narration: return "narration"
    case .description: return "description"
    }
  }

  /// The text a judge grades a rubric-scored task's output against. Extraction doesn't use this
  /// (it's scored via `GoldSet`, not the rubric judge).
  public static func sourceContext(for item: CorpusItem) -> String {
    switch item {
    case .narration(let narrationItem):
      return narrationItem.events.map { "\($0.kind): \($0.summary)" }.joined(separator: "\n")
    case .description(let descriptionItem):
      let context = descriptionItem.context
      return [context.dirName, context.gitRemote, context.manifest,
              context.readmeHead, context.claudeMdHead]
        .compactMap { $0 }.joined(separator: "\n")
    case .extraction:
      return ""
    }
  }

  /// Reduces one model's raw run samples into a `CellScore`, over successful samples only —
  /// a sample whose `outcome != "success"` (transient provider/parse failure) must never drag
  /// down precision/recall/quality (an empty output scored as "found nothing"/"bad prose" would
  /// conflate infra noise with real model failure). If NO sample succeeded, quality/precision/
  /// recall are `nil` (unknown), not 0, so `DecisionEngine` treats the cell as not-clearing.
  public static func score(task: any EvalTask, items: [CorpusItem], samples: [CellSample],
                           spec: ModelSpec, references: ScoringReferences) async -> CellScore {
    let gold = references.gold
    let successfulSamples = samples.filter { $0.outcome == "success" }
    guard !successfulSamples.isEmpty else {
      return CellScore(modelLabel: spec.label, isOnDevice: spec.isOnDevice, quality: nil,
                       precision: nil, recall: nil, costUSD: 0, latencyP50: 0,
                       reproducedFabrication: false)
    }

    // Both axes come off the sample. `estInputTokens` is what `MeasuredProvider` counted at the
    // provider seam; the previous `inputText: ""` priced every prompt at zero, so a model with a
    // 20× longer prompt looked exactly as cheap as a terse one.
    let costs = successfulSamples.map {
      TokenEstimate.costUSD(inputTokens: $0.estInputTokens, outputTokens: $0.estOutputTokens, spec: spec)
    }
    let costUSD = costs.reduce(0, +) / Double(costs.count)
    let latencyP50 = Aggregate.median(successfulSamples.map { $0.latencyMS }) ?? 0

    switch task.scorer {
    case .extraction:
      let scores = goldScores(successfulSamples, gold: gold)
      return CellScore(modelLabel: spec.label, isOnDevice: spec.isOnDevice, quality: nil,
                       precision: scores.precision, recall: scores.recall,
                       costUSD: costUSD, latencyP50: latencyP50,
                       reproducedFabrication: scores.reproducedFabrication)
    case .rubric(let dimensions):
      // No judge ⇒ quality is UNKNOWN, not zero — the same rule as "no sample succeeded" above, so
      // `DecisionEngine` treats the cell as not-clearing rather than as a bad model. `pensieve eval
      // run` skips judge-scored tasks loudly before reaching here; this is the structural guard.
      var quality: Double?
      if let judge = references.judge {
        quality = await rubricQuality(successfulSamples, items: items,
                                      dimensions: dimensions, judge: judge)
      }
      return CellScore(modelLabel: spec.label, isOnDevice: spec.isOnDevice, quality: quality,
                       precision: nil, recall: nil, costUSD: costUSD, latencyP50: latencyP50,
                       reproducedFabrication: false)
    }
  }

  /// The gold-scored axes for one cell. `precision`/`recall` are nil when the gold set says nothing
  /// about any sampled item — unknown, never zero.
  struct GoldScores {
    var precision: Double?
    var recall: Double?
    var reproducedFabrication: Bool
  }

  /// Median precision/recall against the frozen gold set, plus the majority fabrication flag.
  private static func goldScores(_ samples: [CellSample], gold: GoldSet) -> GoldScores {
    var recalls: [Double] = []
    var precisions: [Double] = []
    var fabricationFlags: [Bool] = []
    for sample in samples {
      let surfaced = sample.looseEndQuotes ?? []
      if let recallScore = gold.recallScore(itemID: sample.itemID, surfaced: surfaced) { recalls.append(recallScore) }
      guard let labels = gold.grounding[sample.itemID], !labels.isEmpty else { continue }
      let groundedSet = Set(labels.filter { $0.grounded }.map { $0.quote })
      let fabricatedSet = Set(labels.filter { !$0.grounded }.map { $0.quote })
      let known = surfaced.filter { groundedSet.contains($0) || fabricatedSet.contains($0) }
      if !known.isEmpty {
        precisions.append(Double(known.filter { groundedSet.contains($0) }.count) / Double(known.count))
      }
      fabricationFlags.append(surfaced.contains { fabricatedSet.contains($0) })
    }
    return GoldScores(precision: Aggregate.median(precisions), recall: Aggregate.median(recalls),
                      reproducedFabrication: Aggregate.majorityFabrication(fabricationFlags))
  }

  /// Median judge quality over the samples the judge could actually grade.
  private static func rubricQuality(_ samples: [CellSample], items: [CorpusItem],
                                    dimensions: [String], judge: Judge) async -> Double? {
    let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    var qualities: [Double] = []
    for sample in samples {
      guard let item = itemsByID[sample.itemID] else { continue }
      let verdict = await judge.scoreRubric(output: sample.outputText, dimensions: dimensions,
                                            sourceContext: sourceContext(for: item))
      // A judge that could not answer contributes NOTHING — it must never be read as a zero, which
      // would be indistinguishable from "the model wrote something bad". Logged because, unlike a
      // sample failure (recorded in `CellSample.outcome` and persisted in the scorecard), a judge
      // failure leaves no trace: a total judge outage renders as "no model cleared the bar".
      guard let qualityScore = verdict?.quality else {
        Log.llm.error("""
          CellScoring: judge returned no verdict for \
          \(sample.modelLabel, privacy: .public)/\(sample.itemID, privacy: .public)
          """)
        continue
      }
      qualities.append(qualityScore)
    }
    return Aggregate.median(qualities)
  }
}
