import Foundation
import Testing
@testable import PensieveKit

// MARK: - What the factory actually RETURNS
//
// Everything below this mark asserts on the concrete type `makeDefaultLLMProvider` hands back. The
// tests further down assert on `resolvedProviderKind`, the pure resolver BESIDE the factory — and
// for a long time that was all any of them did. Replacing the factory body with "always return a
// remote cloud provider" left the entire suite green: "extraction stays on-device" and "no API key"
// are the project's privacy guarantees, and nothing checked them. These do.

/// Runs `body` against a throwaway defaults domain, removed afterwards, so nothing here reads or
/// writes the real user's provider selection.
private func withThrowawayDefaults(_ body: (UserDefaults) -> Void) {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  body(defaults)
}

/// The local provider the factory must return: on-device when this machine has it, `claude -p`
/// otherwise. Asserted as a *type*, which is the whole point — a kind string can agree with a
/// factory that returns something else entirely.
private func expectLocalProvider(_ provider: any LLMProvider, _ comment: Comment) {
  #expect(!(provider is CloudLLMProvider), comment)
  #if canImport(FoundationModels)
  if #available(macOS 26.0, *), FoundationModelsProbe.isAvailable() {
    #expect(provider is FoundationModelsProvider, comment)
    return
  }
  #endif
  #expect(provider is ClaudeCLIProvider, comment)
}

/// A fully usable remote cloud config — everything except a *selection* of cloud.
private let configuredRemoteCloud = CloudConfig(flavor: .anthropic,
                                               baseURL: "https://api.anthropic.com",
                                               model: "claude-sonnet-5")

@Test func factoryReturnsTheOnDeviceProviderForTheDefaultSelection() {
  // An untouched domain ⇒ `.auto`, which is what every CLI/daemon extraction run uses.
  withThrowawayDefaults { defaults in
    expectLocalProvider(makeDefaultLLMProvider(defaults: defaults), "auto must resolve on-device-first")
  }
}

@Test func factoryHonorsEachPreferenceWithTheMatchingConcreteType() {
  for preference in [ProviderPreference.auto, .foundationModels] {
    withThrowawayDefaults { defaults in
      defaults.set(preference.rawValue, forKey: PensieveDefaults.llmProviderKey)
      expectLocalProvider(makeDefaultLLMProvider(defaults: defaults), "\(preference) must stay local")
    }
  }
  withThrowawayDefaults { defaults in
    defaults.set(ProviderPreference.claudeCLI.rawValue, forKey: PensieveDefaults.llmProviderKey)
    // An explicit CLI choice is never upgraded to on-device, even on a capable machine.
    #expect(makeDefaultLLMProvider(defaults: defaults) is ClaudeCLIProvider)
  }
}

@Test func noConfigurationReachableWithoutAnExplicitCloudOptInReturnsTheCloudProvider() {
  // Every way to reach the factory short of "select Cloud AND finish configuring it". None may
  // return CloudLLMProvider: there is no API key on this machine, and extraction stays on-device.
  for preference in [ProviderPreference.auto, .foundationModels] {
    withThrowawayDefaults { defaults in
      defaults.set(preference.rawValue, forKey: PensieveDefaults.llmProviderKey)
      // Even WITH a fully configured cloud sitting there, a non-cloud selection must not use it.
      expectLocalProvider(
        makeDefaultLLMProvider(defaults: defaults, cloudConfig: configuredRemoteCloud, apiKey: "sk-test"),
        "\(preference) selected: a configured cloud must not be reached")
    }
  }
  withThrowawayDefaults { defaults in
    defaults.set(ProviderPreference.claudeCLI.rawValue, forKey: PensieveDefaults.llmProviderKey)
    #expect(makeDefaultLLMProvider(defaults: defaults,
                                   cloudConfig: configuredRemoteCloud, apiKey: "sk-test") is ClaudeCLIProvider)
  }

  // Cloud *selected*, but not usable: no config, no key, no model, no base URL. Each degrades local.
  let unusable: [(CloudConfig?, String?)] = [
    (nil, nil),
    (nil, "sk-test"),
    (configuredRemoteCloud, nil),
    (configuredRemoteCloud, ""),
    (CloudConfig(flavor: .anthropic, baseURL: "https://api.anthropic.com", model: ""), "sk-test"),
    (CloudConfig(flavor: .anthropic, baseURL: "", model: "claude-sonnet-5"), "sk-test"),
  ]
  for (config, key) in unusable {
    withThrowawayDefaults { defaults in
      defaults.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
      expectLocalProvider(makeDefaultLLMProvider(defaults: defaults, cloudConfig: config, apiKey: key),
                          "cloud selected but unconfigured must degrade to local")
    }
  }
}

@Test func factoryReturnsTheCloudProviderOnlyForADeliberatelyConfiguredCloudSelection() {
  // The presence half: "never cloud" above is only meaningful if the opt-in path genuinely works,
  // otherwise it would pass by the factory simply never returning cloud at all.
  withThrowawayDefaults { defaults in
    defaults.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
    #expect(makeDefaultLLMProvider(defaults: defaults,
                                   cloudConfig: configuredRemoteCloud, apiKey: "sk-test") is CloudLLMProvider)

    // And the keyless-localhost case (Ollama), which `resolvedProviderKind` already calls "cloud".
    let localEndpoint = CloudConfig(flavor: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "llama3")
    #expect(makeDefaultLLMProvider(defaults: defaults, cloudConfig: localEndpoint, apiKey: "") is CloudLLMProvider)
  }
}

// MARK: - The resolver beside it

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
