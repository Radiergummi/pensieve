import Foundation
import Testing
@testable import PensieveKit

@Test func defaultProviderIsSelectable() async throws {
  let provider = makeDefaultLLMProvider()
  // On macOS 26 with the model enabled this is FoundationModelsProvider; otherwise Claude.
  // Either way we get a usable LLMProvider value.
  _ = provider

  let kind = defaultProviderKind()
  if FoundationModelsProbe.availabilityDescription() == "available" {
    #expect(kind == "foundationModels")
  } else {
    #expect(kind == "claudeCLI")
  }
}
