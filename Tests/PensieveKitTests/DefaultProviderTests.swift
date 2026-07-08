import Foundation
import Testing
@testable import PensieveKit

@Test func defaultProviderIsSelectable() async throws {
  // Force the .auto path by pointing at a nonexistent prefs file, so this test asserts the
  // machine's native availability regardless of the real ~/Library preferences.json.
  let noPrefs = URL(fileURLWithPath: "/nonexistent/pensieve-prefs-\(UUID().uuidString).json")

  let provider = makeDefaultLLMProvider(prefsURL: noPrefs)
  _ = provider   // either FoundationModelsProvider or Claude — both are usable LLMProviders

  let kind = defaultProviderKind(prefsURL: noPrefs)
  if FoundationModelsProbe.availabilityDescription() == "available" {
    #expect(kind == "foundationModels")
  } else {
    #expect(kind == "claudeCLI")
  }
}
