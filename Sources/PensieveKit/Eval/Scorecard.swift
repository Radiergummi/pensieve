// Sources/PensieveKit/Eval/Scorecard.swift
import Foundation

public struct CellScore: Sendable, Codable, Equatable {
  public var modelLabel: String
  public var isOnDevice: Bool
  public var quality: Double?
  public var precision: Double?
  public var recall: Double?
  public var costUSD: Double
  public var latencyP50: Double
  public var reproducedFabrication: Bool
  public init(modelLabel: String, isOnDevice: Bool, quality: Double?, precision: Double?, recall: Double?, costUSD: Double, latencyP50: Double, reproducedFabrication: Bool) {
    self.modelLabel = modelLabel; self.isOnDevice = isOnDevice; self.quality = quality; self.precision = precision
    self.recall = recall; self.costUSD = costUSD; self.latencyP50 = latencyP50; self.reproducedFabrication = reproducedFabrication
  }
}

public struct EffectiveBar: Sendable, Equatable {
  public var precision: Double?; public var recall: Double?; public var quality: Double?
  public init(precision: Double?, recall: Double?, quality: Double?) { self.precision = precision; self.recall = recall; self.quality = quality }
}

public struct Recommendation: Sendable, Codable, Equatable {
  public var task: String; public var winner: String; public var clearedBar: [String]; public var reason: String
}

public enum Aggregate {
  public static func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted(); let n = s.count
    return n % 2 == 1 ? s[n/2] : (s[n/2 - 1] + s[n/2]) / 2
  }
  public static func majorityFabrication(_ flags: [Bool]) -> Bool {
    guard !flags.isEmpty else { return false }
    return flags.filter { $0 }.count * 2 > flags.count
  }
}

public enum DecisionEngine {
  public static func effectiveBar(task: String, config: EvalConfig, incumbent: CellScore?) -> EffectiveBar {
    let bar = config.bar(for: task)
    if bar?.inheritFromIncumbent == true, let inc = incumbent {
      return EffectiveBar(precision: inc.precision, recall: inc.recall, quality: inc.quality)
    }
    return EffectiveBar(precision: bar?.precision, recall: bar?.recall, quality: bar?.quality)
  }

  public static func recommend(task: String, scores: [CellScore], bar: EffectiveBar,
                               incumbentLabel: String, noiseMargin: Double) -> Recommendation {
    // A model clears the bar only ROBUSTLY (by ≥ noiseMargin on soft axes). The precision
    // hard-gate (reproduced fabrication) excludes a model regardless of every other score —
    // and it applies to EVERYONE, including the on-device incumbent.
    func clears(_ s: CellScore) -> Bool {
      if task == "extraction" && s.reproducedFabrication { return false }
      if let p = bar.precision, (s.precision ?? -1) + 1e-9 < p { return false }
      if let r = bar.recall, (s.recall ?? -1) + 1e-9 < r + noiseMargin { return false }
      if let q = bar.quality, (s.quality ?? -1) + 1e-9 < q + noiseMargin { return false }
      return true
    }
    let cleared = scores.filter(clears)
    let clearedLabels = cleared.map { $0.modelLabel }

    // Local-first: rank bar-clearing models by locality → cost → latency → quality. The on-device
    // incumbent ($0, local) tops this whenever it clears, so we never switch to cloud merely for
    // quality-above-bar. A challenger wins only when the incumbent is EXCLUDED (failed the bar or
    // reproduced a fabrication).
    let ranked = cleared.sorted { a, b in
      if a.isOnDevice != b.isOnDevice { return a.isOnDevice && !b.isOnDevice }
      if a.costUSD != b.costUSD { return a.costUSD < b.costUSD }
      if a.latencyP50 != b.latencyP50 { return a.latencyP50 < b.latencyP50 }
      return (a.quality ?? 0) > (b.quality ?? 0)
    }
    guard let winner = ranked.first else {
      return Recommendation(task: task, winner: incumbentLabel, clearedBar: clearedLabels,
                            reason: "no model cleared the bar; fell back to incumbent")
    }
    let reason = winner.modelLabel == incumbentLabel
      ? "incumbent clears the bar (local-first)"
      : "incumbent excluded; cheapest-local bar-clearing model by locality→cost→latency→quality"
    return Recommendation(task: task, winner: winner.modelLabel, clearedBar: clearedLabels, reason: reason)
  }
}
