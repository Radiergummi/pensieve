// Tests/PensieveKitTests/TokenEstimateTests.swift
import Testing
@testable import PensieveKit

@Test func tokensAreCharsOverFourCeil() {
  #expect(TokenEstimate.tokens("") == 0)
  #expect(TokenEstimate.tokens("abcd") == 1)
  #expect(TokenEstimate.tokens("abcde") == 2)
}
@Test func onDeviceCostsZero() {
  let fm = ModelSpec(label: "apple/foundation-models", kind: "foundationModels", flavor: nil, baseURL: nil, model: nil, inputPricePerM: 0, outputPricePerM: 0)
  #expect(TokenEstimate.costUSD(inputText: String(repeating: "x", count: 4000), outputText: "yyyy", spec: fm) == 0)
}
@Test func cloudCostUsesPrices() {
  let m = ModelSpec(label: "openai/gpt-5-nano", kind: "cloud", flavor: .openAICompatible, baseURL: "b", model: "m", inputPricePerM: 1.0, outputPricePerM: 2.0)
  // 4_000_000 chars → 1_000_000 input tokens → $1.0; 8_000_000 chars → 2_000_000 output tokens → $4.0
  let cost = TokenEstimate.costUSD(inputText: String(repeating: "x", count: 4_000_000), outputText: String(repeating: "y", count: 8_000_000), spec: m)
  #expect(abs(cost - 5.0) < 1e-6)
}
