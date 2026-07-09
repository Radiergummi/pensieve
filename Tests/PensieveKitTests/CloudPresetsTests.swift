import Foundation
import Testing
@testable import PensieveKit

@Test func presetsMatchByFlavorAndBaseURL() {
  let openai = CloudPresets.all.first { $0.id == "openai" }!
  #expect(CloudPresets.match(flavor: openai.flavor, baseURL: openai.baseURL)?.id == "openai")

  let anthropic = CloudPresets.all.first { $0.id == "anthropic" }!
  #expect(CloudPresets.match(flavor: anthropic.flavor, baseURL: anthropic.baseURL)?.id == "anthropic")
}

@Test func editedBaseURLReadsAsCustom() {
  // Matching flavor but a base URL that isn't any preset ⇒ nil (Custom).
  #expect(CloudPresets.match(flavor: .openAICompatible, baseURL: "https://gateway.example/v1") == nil)
  #expect(CloudPresets.match(flavor: .anthropic, baseURL: "https://api.anthropic.com/edited") == nil)
}

@Test func distinctVendorsOfSameFlavorHaveDistinctIDs() {
  let openAICompatIDs = CloudPresets.all.filter { $0.flavor == .openAICompatible }.map(\.id)
  #expect(Set(openAICompatIDs).count == openAICompatIDs.count)   // no dupes
  #expect(openAICompatIDs.contains("openai") && openAICompatIDs.contains("groq"))
}

@Test func keychainAccountIsPerVendorElseCustom() {
  #expect(CloudPresets.keychainAccount(flavor: .openAICompatible, baseURL: "https://api.openai.com/v1") == "openai")
  #expect(CloudPresets.keychainAccount(flavor: .openAICompatible, baseURL: "https://api.groq.com/openai/v1") == "groq")
  #expect(CloudPresets.keychainAccount(flavor: .anthropic, baseURL: "https://api.anthropic.com") == "anthropic")
  // Unknown URL ⇒ a per-flavor custom slot, distinct across flavors.
  #expect(CloudPresets.keychainAccount(flavor: .openAICompatible, baseURL: "https://x/v1") == "custom.openAICompatible")
  #expect(CloudPresets.keychainAccount(flavor: .anthropic, baseURL: "https://x") == "custom.anthropic")
}
