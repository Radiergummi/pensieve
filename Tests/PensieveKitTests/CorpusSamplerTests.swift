// Tests/PensieveKitTests/CorpusSamplerTests.swift
import Testing
@testable import PensieveKit

private func pool() -> [PoolEntry<Int>] {
  (0..<40).map { PoolEntry(strata: ["short", "long", "compacted"][$0 % 3], isStress: $0 == 7, item: $0) }
}

@Test func sameSeedSameSelection() {
  let firstSelection = CorpusSampler.select(from: pool(), size: 10, seed: 42)
  let secondSelection = CorpusSampler.select(from: pool(), size: 10, seed: 42)
  #expect(firstSelection == secondSelection)
}
@Test func differentSeedDiffers() {
  let firstSelection = CorpusSampler.select(from: pool(), size: 10, seed: 1)
  let secondSelection = CorpusSampler.select(from: pool(), size: 10, seed: 2)
  #expect(firstSelection != secondSelection)
}
@Test func stressItemsAlwaysIncluded() {
  let selection = CorpusSampler.select(from: pool(), size: 3, seed: 99)
  #expect(selection.contains(7)) // the stress item survives even a tiny sample
}
@Test func spreadsAcrossStrata() {
  let picks = CorpusSampler.select(from: pool(), size: 9, seed: 5)
  let strataOf = Dictionary(uniqueKeysWithValues: pool().map { ($0.item, $0.strata) })
  let kinds = Set(picks.map { strataOf[$0]! })
  #expect(kinds.count == 3) // all three shapes represented
}
