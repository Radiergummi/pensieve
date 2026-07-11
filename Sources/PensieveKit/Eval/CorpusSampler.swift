// Sources/PensieveKit/Eval/CorpusSampler.swift
import Foundation

public struct SeededRNG: RandomNumberGenerator {
  private var state: UInt64
  public init(seed: UInt64) { state = seed }
  public mutating func next() -> UInt64 {   // SplitMix64
    state &+= 0x9E3779B97F4A7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    return z ^ (z >> 31)
  }
}

public enum CorpusSampler {
  public static func select<T>(from pool: [(strata: String, isStress: Bool, item: T)],
                               size: Int, seed: UInt64) -> [T] {
    var rng = SeededRNG(seed: seed)
    let stress = pool.filter { $0.isStress }
    var chosen = stress.map { $0.item }
    var remaining = size - chosen.count
    if remaining <= 0 { return chosen }

    // Group non-stress by strata, shuffle each group deterministically.
    var byStrata: [String: [T]] = [:]
    for entry in pool where !entry.isStress { byStrata[entry.strata, default: []].append(entry.item) }
    let strataOrder = byStrata.keys.sorted()
    var queues = strataOrder.map { key -> [T] in
      var arr = byStrata[key]!
      arr.shuffle(using: &rng)
      return arr
    }
    // Round-robin across strata until we hit `size` or exhaust the pool.
    var idx = 0
    while remaining > 0 && queues.contains(where: { !$0.isEmpty }) {
      let q = idx % queues.count
      if !queues[q].isEmpty { chosen.append(queues[q].removeLast()); remaining -= 1 }
      idx += 1
    }
    return chosen
  }
}
