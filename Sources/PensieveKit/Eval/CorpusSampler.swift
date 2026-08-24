// Sources/PensieveKit/Eval/CorpusSampler.swift
import Foundation

public struct SeededRNG: RandomNumberGenerator {
  private var state: UInt64
  public init(seed: UInt64) { state = seed }
  public mutating func next() -> UInt64 {   // SplitMix64
    state &+= 0x9E3779B97F4A7C15
    var hashValue = state
    hashValue = (hashValue ^ (hashValue >> 30)) &* 0xBF58476D1CE4E5B9
    hashValue = (hashValue ^ (hashValue >> 27)) &* 0x94D049BB133111EB
    return hashValue ^ (hashValue >> 31)
  }
}

/// One entry in a sampling pool: which stratum it belongs to, whether it is a mandatory stress
/// case, and the pooled item itself.
public struct PoolEntry<Item> {
  public var strata: String
  public var isStress: Bool
  public var item: Item

  public init(strata: String, isStress: Bool, item: Item) {
    self.strata = strata
    self.isStress = isStress
    self.item = item
  }
}

public enum CorpusSampler {
  public static func select<T>(from pool: [PoolEntry<T>],
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
      var stratum = byStrata[key]!
      stratum.shuffle(using: &rng)
      return stratum
    }
    // Round-robin across strata until we hit `size` or exhaust the pool.
    var cursor = 0
    while remaining > 0 && queues.contains(where: { !$0.isEmpty }) {
      let queueIndex = cursor % queues.count
      if !queues[queueIndex].isEmpty { chosen.append(queues[queueIndex].removeLast()); remaining -= 1 }
      cursor += 1
    }
    return chosen
  }
}
