import Foundation

public enum ModelProviderFactory {
  public static func apiKeyAccount(for spec: ModelSpec) -> String { spec.label }

  public static func needsKey(_ spec: ModelSpec) -> Bool {
    guard !spec.isOnDevice else { return false }
    let cfg = cloudConfig(spec)
    return !(cfg?.isLocalEndpoint ?? false)
  }

  public static func make(_ spec: ModelSpec, apiKey: String?) -> (any LLMProvider)? {
    if spec.isOnDevice {
      #if canImport(FoundationModels)
      if #available(macOS 26.0, *) { return FoundationModelsProvider() }
      #endif
      return nil
    }
    guard let cfg = cloudConfig(spec), cfg.isUsable else { return nil }
    if needsKey(spec) && (apiKey == nil || apiKey!.isEmpty) { return nil }
    return CloudLLMProvider(config: cfg, apiKey: apiKey ?? "")
  }

  private static func cloudConfig(_ spec: ModelSpec) -> CloudConfig? {
    guard let flavor = spec.flavor, let base = spec.baseURL, let model = spec.model else { return nil }
    return CloudConfig(flavor: flavor, baseURL: base, model: model)
  }
}
