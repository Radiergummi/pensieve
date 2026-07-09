import Foundation
import Testing
@testable import PensieveKit

@Test func flavorDefaultsAndSuffixes() {
  #expect(CloudFlavor.anthropic.defaultBaseURL == "https://api.anthropic.com")
  #expect(CloudFlavor.openAICompatible.defaultBaseURL == "https://api.openai.com/v1")
  #expect(CloudFlavor.anthropic.completionSuffix == "/v1/messages")
  #expect(CloudFlavor.openAICompatible.completionSuffix == "/chat/completions")
  #expect(CloudFlavor.anthropic.modelsSuffix == "/v1/models")
  #expect(CloudFlavor.openAICompatible.modelsSuffix == "/models")
}

@Test func configIsUsableRequiresBaseAndModel() {
  #expect(CloudConfig(flavor: .anthropic, baseURL: "https://x", model: "m").isUsable)
  #expect(!CloudConfig(flavor: .anthropic, baseURL: "", model: "m").isUsable)
  #expect(!CloudConfig(flavor: .anthropic, baseURL: "https://x", model: "").isUsable)
}
