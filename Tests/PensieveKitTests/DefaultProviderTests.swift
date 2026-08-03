import Foundation
import Testing
@testable import PensieveKit

@Test func factoryFallsBackToLocalWithoutCloudInputs() {
  // An empty throwaway domain ⇒ selection == .auto ⇒ a usable local provider (never cloud).
  let suite = "pensieve-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let provider = makeDefaultLLMProvider(defaults: defaults)
  _ = provider   // FoundationModelsProvider or ClaudeCLIProvider — both usable LLMProviders

  let kind = resolveProviderKind(preference: .auto,
                                 foundationAvailable: FoundationModelsProbe.isAvailable(),
                                 cloudConfigured: false)
  #expect(kind == "foundationModels" || kind == "claudeCLI")
}

@Test func cloudSelectionWithoutKeyFallsBackToLocal() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  // .cloud selected but no cloudConfig/apiKey passed ⇒ not configured ⇒ local provider, no crash.
  let provider = makeDefaultLLMProvider(defaults: defaults)
  _ = provider
}

@Test func resolvedProviderKindMatchesMakeDefaultLLMProvider() {
  // An empty throwaway domain ⇒ selection == .auto, no cloud inputs ⇒ a local kind.
  let suite = "pensieve-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let kind = resolvedProviderKind(defaults: defaults)
  #expect(kind == "foundationModels" || kind == "claudeCLI")

  // .cloud selected but no cloudConfig/apiKey ⇒ not configured ⇒ still a local kind, never "cloud".
  let suite2 = "pensieve-test-\(UUID().uuidString)"
  let secondDefaults = UserDefaults(suiteName: suite2)!
  defer { secondDefaults.removePersistentDomain(forName: suite2) }
  secondDefaults.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  let cloudKind = resolvedProviderKind(defaults: secondDefaults)
  #expect(cloudKind == "foundationModels" || cloudKind == "claudeCLI")
}

@Test func keylessLocalhostCloudResolvesToCloud() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  let cloudConfig = CloudConfig(flavor: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "llama3")
  // Empty key + local endpoint ⇒ configured ⇒ "cloud".
  #expect(resolvedProviderKind(defaults: defaults, cloudConfig: cloudConfig, apiKey: "") == "cloud")
  // And the factory must not crash on the nil/empty key.
  _ = makeDefaultLLMProvider(defaults: defaults, cloudConfig: cloudConfig, apiKey: nil)
}

@Test func keylessRemoteCloudFallsBackToLocal() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  let cloudConfig = CloudConfig(flavor: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-4o")
  let kind = resolvedProviderKind(defaults: defaults, cloudConfig: cloudConfig, apiKey: "")
  #expect(kind == "foundationModels" || kind == "claudeCLI")
}

// MARK: - CloudConfig.fromDefaults

@Test func cloudConfigDefaultsToAnthropicWhenTheFlavorWasNeverPersisted() {
  // The bug this guards: @AppStorage never writes its own default, so a user who selects
  // "Cloud (API)" and keeps the default Anthropic vendor leaves `cloudFlavor` UNSET. Reading it
  // with a bare `guard let` yielded no config at all → cloud silently degraded to local while
  // Settings still displayed "Cloud (API)". An unset flavor must mean anthropic — what the UI shows.
  let suite = "pensieve-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set("claude-sonnet-5", forKey: PensieveDefaults.cloudModelKey)   // model chosen, vendor untouched

  let config = CloudConfig.fromDefaults(defaults)
  #expect(config.flavor == .anthropic)
  #expect(config.baseURL == CloudFlavor.anthropic.defaultBaseURL)   // empty stored ⇒ flavor default
  #expect(config.model == "claude-sonnet-5")
  #expect(config.isUsable)   // ⇒ with a key present, resolvedProviderKind now returns "cloud"

  defaults.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  #expect(resolvedProviderKind(defaults: defaults, cloudConfig: config, apiKey: "sk-test") == "cloud")
}

@Test func cloudConfigHonorsAPersistedFlavorAndBaseURL() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(CloudFlavor.openAICompatible.rawValue, forKey: PensieveDefaults.cloudFlavorKey)
  defaults.set("https://api.groq.com/openai/v1", forKey: PensieveDefaults.cloudBaseURLKey)

  let config = CloudConfig.fromDefaults(defaults)
  #expect(config.flavor == .openAICompatible)
  #expect(config.baseURL == "https://api.groq.com/openai/v1")
  #expect(config.model.isEmpty)
  #expect(!config.isUsable)   // no model ⇒ not configured ⇒ still degrades to local
}
