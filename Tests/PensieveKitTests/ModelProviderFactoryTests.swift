import Testing
@testable import PensieveKit

private let onDevice = ModelSpec(label: "apple/foundation-models", kind: "foundationModels", flavor: nil, baseURL: nil,
                                  model: nil, inputPricePerM: 0, outputPricePerM: 0)
private let cloud = ModelSpec(label: "openai/gpt-5-nano", kind: "cloud", flavor: .openAICompatible,
                               baseURL: "https://api.openai.com/v1", model: "gpt-5-nano", inputPricePerM: 0.05, outputPricePerM: 0.4)

@Test func keyAccountIsTheLabel() {
  #expect(ModelProviderFactory.apiKeyAccount(for: cloud) == "openai/gpt-5-nano")
}
@Test func onDeviceNeedsNoKey() {
  #expect(ModelProviderFactory.needsKey(onDevice) == false)
  #expect(ModelProviderFactory.needsKey(cloud) == true)
}
@Test func cloudWithoutKeyIsNil() {
  #expect(ModelProviderFactory.make(cloud, apiKey: nil) == nil)
}
@Test func cloudWithKeyBuildsProvider() {
  #expect(ModelProviderFactory.make(cloud, apiKey: "sk-x") != nil)
}
