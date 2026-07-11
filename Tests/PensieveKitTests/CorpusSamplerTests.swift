// Tests/PensieveKitTests/CorpusSamplerTests.swift
import Testing
@testable import PensieveKit

private func pool() -> [(strata: String, isStress: Bool, item: Int)] {
  (0..<40).map { (strata: ["short","long","compacted"][$0 % 3], isStress: $0 == 7, item: $0) }
}

@Test func sameSeedSameSelection() {
  let a = CorpusSampler.select(from: pool(), size: 10, seed: 42)
  let b = CorpusSampler.select(from: pool(), size: 10, seed: 42)
  #expect(a == b)
}
@Test func differentSeedDiffers() {
  let a = CorpusSampler.select(from: pool(), size: 10, seed: 1)
  let b = CorpusSampler.select(from: pool(), size: 10, seed: 2)
  #expect(a != b)
}
@Test func stressItemsAlwaysIncluded() {
  let a = CorpusSampler.select(from: pool(), size: 3, seed: 99)
  #expect(a.contains(7)) // the stress item survives even a tiny sample
}
@Test func spreadsAcrossStrata() {
  let picks = CorpusSampler.select(from: pool(), size: 9, seed: 5)
  let strataOf = Dictionary(uniqueKeysWithValues: pool().map { ($0.item, $0.strata) })
  let kinds = Set(picks.map { strataOf[$0]! })
  #expect(kinds.count == 3) // all three shapes represented
}
