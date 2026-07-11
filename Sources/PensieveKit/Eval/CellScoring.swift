// Sources/PensieveKit/Eval/CellScoring.swift
import Foundation

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
    case .narration(let n):
      return n.events.map { "\($0.kind): \($0.summary)" }.joined(separator: "\n")
    case .description(let d):
      return [d.context.dirName, d.context.gitRemote, d.context.manifest, d.context.readmeHead, d.context.claudeMdHead]
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
                           spec: ModelSpec, gold: GoldSet, judge: Judge) async -> CellScore {
    let ok = samples.filter { $0.outcome == "success" }
    guard !ok.isEmpty else {
      return CellScore(modelLabel: spec.label, isOnDevice: spec.isOnDevice, quality: nil,
                       precision: nil, recall: nil, costUSD: 0, latencyP50: 0,
                       reproducedFabrication: false)
    }

    let costs = ok.map { TokenEstimate.costUSD(inputText: "", outputText: $0.outputText, spec: spec) }
    let costUSD = costs.reduce(0, +) / Double(costs.count)
    let latencyP50 = Aggregate.median(ok.map { $0.latencyMS }) ?? 0

    switch task.scorer {
    case .extraction:
      var recalls: [Double] = []
      var precisions: [Double] = []
      var fabFlags: [Bool] = []
      for sample in ok {
        let surfaced = sample.looseEndQuotes ?? []
        if let r = gold.recallScore(itemID: sample.itemID, surfaced: surfaced) { recalls.append(r) }
        if let labels = gold.grounding[sample.itemID], !labels.isEmpty {
          let groundedSet = Set(labels.filter { $0.grounded }.map { $0.quote })
          let fabricatedSet = Set(labels.filter { !$0.grounded }.map { $0.quote })
          let known = surfaced.filter { groundedSet.contains($0) || fabricatedSet.contains($0) }
          if !known.isEmpty {
            precisions.append(Double(known.filter { groundedSet.contains($0) }.count) / Double(known.count))
          }
          fabFlags.append(surfaced.contains { fabricatedSet.contains($0) })
        }
      }
      return CellScore(modelLabel: spec.label, isOnDevice: spec.isOnDevice, quality: nil,
                       precision: Aggregate.median(precisions), recall: Aggregate.median(recalls),
                       costUSD: costUSD, latencyP50: latencyP50,
                       reproducedFabrication: Aggregate.majorityFabrication(fabFlags))
    case .rubric(let dims):
      let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
      var qualities: [Double] = []
      for sample in ok {
        guard let item = itemsByID[sample.itemID] else { continue }
        let verdict = await judge.scoreRubric(output: sample.outputText, dimensions: dims,
                                              sourceContext: sourceContext(for: item))
        if let q = verdict?.quality { qualities.append(q) }
      }
      return CellScore(modelLabel: spec.label, isOnDevice: spec.isOnDevice, quality: Aggregate.median(qualities),
                       precision: nil, recall: nil, costUSD: costUSD, latencyP50: latencyP50,
                       reproducedFabrication: false)
    }
  }
}
