import Foundation

public enum ModelProviderFactory {
  public static func apiKeyAccount(for spec: ModelSpec) -> String { spec.label }

  /// `claudeCLI` authenticates through the Claude subscription, so it needs no key — the same reason
  /// on-device and a local endpoint need none.
  public static func needsKey(_ spec: ModelSpec) -> Bool {
    guard !spec.isOnDevice, spec.kind != ModelSpec.claudeCLIKind else { return false }
    let cloudConfiguration = cloudConfig(spec)
    return !(cloudConfiguration?.isLocalEndpoint ?? false)
  }

  public static func make(_ spec: ModelSpec, apiKey: String?) -> (any LLMProvider)? {
    if spec.isOnDevice {
      #if canImport(FoundationModels)
      if #available(macOS 26.0, *) { return FoundationModelsProvider() }
      #endif
      return nil
    }
    // No `baseURL`/`model`/`flavor`: `claude -p` picks its own model from the CLI's configuration,
    // so a roster entry is just a label and (zero) prices.
    if spec.kind == ModelSpec.claudeCLIKind { return ClaudeCLIProvider() }
    guard let cloudConfiguration = cloudConfig(spec), cloudConfiguration.isUsable else { return nil }
    if needsKey(spec), apiKey?.isEmpty ?? true { return nil }
    return CloudLLMProvider(config: cloudConfiguration, apiKey: apiKey ?? "")
  }

  private static func cloudConfig(_ spec: ModelSpec) -> CloudConfig? {
    guard let flavor = spec.flavor, let baseURL = spec.baseURL, let model = spec.model else { return nil }
    return CloudConfig(flavor: flavor, baseURL: baseURL, model: model)
  }
}
