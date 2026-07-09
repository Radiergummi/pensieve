import Foundation

/// True when Foundation Models is compiled in, requires macOS 26+, and the on-device model reports
/// itself available on this machine. Shared by the factory and the resolver so they can't disagree.
private func foundationModelsIsSelectable() -> Bool {
  FoundationModelsProbe.isAvailable()
}

/// The whole provider decision as one pure function. Returns the concrete kind string
/// (`"foundationModels"` / `"claudeCLI"` / `"cloud"`) — never a preference case. Forced Foundation
/// Models and a `.cloud` selection that isn't configured both fall back to local-first the same way.
/// `cloudConfigured` is computed by the caller from config validity + key presence.
public func resolveProviderKind(preference: ProviderPreference,
                                foundationAvailable: Bool,
                                cloudConfigured: Bool) -> String {
  let local = foundationAvailable ? "foundationModels" : "claudeCLI"
  switch preference {
  case .cloud:
    return cloudConfigured ? "cloud" : local
  case .auto, .foundationModels:
    return local
  case .claudeCLI:
    return "claudeCLI"
  }
}

/// The resolved concrete provider kind ("foundationModels" / "claudeCLI" / "cloud") for the given
/// selection + cloud inputs. Single source of truth shared by the factory and the app's cache key.
public func resolvedProviderKind(defaults: UserDefaults = .standard,
                                 cloudConfig: CloudConfig? = nil,
                                 apiKey: String? = nil) -> String {
  let preference = ProviderSettings.selection(from: defaults)
  let configured = (cloudConfig?.isUsable ?? false)
    && (!(apiKey ?? "").isEmpty || (cloudConfig?.isLocalEndpoint ?? false))
  return resolveProviderKind(preference: preference,
                             foundationAvailable: foundationModelsIsSelectable(),
                             cloudConfigured: configured)
}

/// Preference-aware selection. The *selection* comes from an injected UserDefaults (app → `.standard`;
/// CLI/daemon → `PensieveDefaults.shared()`); the app additionally injects the cloud config + Keychain
/// key. Cloud is chosen only when selected AND fully configured, else it degrades to local-first.
public func makeDefaultLLMProvider(defaults: UserDefaults = .standard,
                                   cloudConfig: CloudConfig? = nil,
                                   apiKey: String? = nil) -> any LLMProvider {
  let kind = resolvedProviderKind(defaults: defaults, cloudConfig: cloudConfig, apiKey: apiKey)
  switch kind {
  case "cloud":
    return CloudLLMProvider(config: cloudConfig!, apiKey: apiKey ?? "")
  case "foundationModels":
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) { return FoundationModelsProvider() }
    #endif
    return ClaudeCLIProvider()
  default:
    return ClaudeCLIProvider()
  }
}
