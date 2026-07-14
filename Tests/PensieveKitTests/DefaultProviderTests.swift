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

@Test func keylessLocalhostCloudResolvesToCloud() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  d.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  let cfg = CloudConfig(flavor: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "llama3")
  // Empty key + local endpoint ⇒ configured ⇒ "cloud".
  #expect(resolvedProviderKind(defaults: d, cloudConfig: cfg, apiKey: "") == "cloud")
  // And the factory must not crash on the nil/empty key.
  _ = makeDefaultLLMProvider(defaults: d, cloudConfig: cfg, apiKey: nil)
}

@Test func keylessRemoteCloudFallsBackToLocal() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  d.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  let cfg = CloudConfig(flavor: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-4o")
  let kind = resolvedProviderKind(defaults: d, cloudConfig: cfg, apiKey: "")
  #expect(kind == "foundationModels" || kind == "claudeCLI")
}

// MARK: - CloudConfig.fromDefaults

@Test func cloudConfigDefaultsToAnthropicWhenTheFlavorWasNeverPersisted() {
  // The bug this guards: @AppStorage never writes its own default, so a user who selects
  // "Cloud (API)" and keeps the default Anthropic vendor leaves `cloudFlavor` UNSET. Reading it
  // with a bare `guard let` yielded no config at all → cloud silently degraded to local while
  // Settings still displayed "Cloud (API)". An unset flavor must mean anthropic — what the UI shows.
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  d.set("claude-sonnet-5", forKey: PensieveDefaults.cloudModelKey)   // model chosen, vendor untouched

  let config = CloudConfig.fromDefaults(d)
  #expect(config.flavor == .anthropic)
  #expect(config.baseURL == CloudFlavor.anthropic.defaultBaseURL)   // empty stored ⇒ flavor default
  #expect(config.model == "claude-sonnet-5")
  #expect(config.isUsable)   // ⇒ with a key present, resolvedProviderKind now returns "cloud"

  d.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  #expect(resolvedProviderKind(defaults: d, cloudConfig: config, apiKey: "sk-test") == "cloud")
}

@Test func cloudConfigHonorsAPersistedFlavorAndBaseURL() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  d.set(CloudFlavor.openAICompatible.rawValue, forKey: PensieveDefaults.cloudFlavorKey)
  d.set("https://api.groq.com/openai/v1", forKey: PensieveDefaults.cloudBaseURLKey)

  let config = CloudConfig.fromDefaults(d)
  #expect(config.flavor == .openAICompatible)
  #expect(config.baseURL == "https://api.groq.com/openai/v1")
  #expect(config.model.isEmpty)
  #expect(!config.isUsable)   // no model ⇒ not configured ⇒ still degrades to local
}
