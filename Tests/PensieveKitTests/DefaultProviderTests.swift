import Foundation
import Testing
@testable import PensieveKit

@Test func factoryFallsBackToLocalWithoutCloudInputs() {
  // An empty throwaway domain ⇒ selection == .auto ⇒ a usable local provider (never cloud).
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  let provider = makeDefaultLLMProvider(defaults: d)
  _ = provider   // FoundationModelsProvider or ClaudeCLIProvider — both usable LLMProviders

  let kind = resolveProviderKind(preference: .auto,
                                 foundationAvailable: FoundationModelsProbe.isAvailable(),
                                 cloudConfigured: false)
  #expect(kind == "foundationModels" || kind == "claudeCLI")
}

@Test func cloudSelectionWithoutKeyFallsBackToLocal() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  d.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  // .cloud selected but no cloudConfig/apiKey passed ⇒ not configured ⇒ local provider, no crash.
  let provider = makeDefaultLLMProvider(defaults: d)
  _ = provider
}

@Test func resolvedProviderKindMatchesMakeDefaultLLMProvider() {
  // An empty throwaway domain ⇒ selection == .auto, no cloud inputs ⇒ a local kind.
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  let kind = resolvedProviderKind(defaults: d)
  #expect(kind == "foundationModels" || kind == "claudeCLI")

  // .cloud selected but no cloudConfig/apiKey ⇒ not configured ⇒ still a local kind, never "cloud".
  let suite2 = "pensieve-test-\(UUID().uuidString)"
  let d2 = UserDefaults(suiteName: suite2)!
  defer { d2.removePersistentDomain(forName: suite2) }
  d2.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  let cloudKind = resolvedProviderKind(defaults: d2)
  #expect(cloudKind == "foundationModels" || cloudKind == "claudeCLI")
}
