import Foundation

/// True when Foundation Models is compiled in, requires macOS 26+, and the on-device
/// model reports itself available on this machine. Shared by the factory and the resolver
/// so they can never disagree.
private func foundationModelsIsSelectable() -> Bool {
  FoundationModelsProbe.isAvailable()
}

/// The whole provider decision as one pure function. Returns the concrete kind string
/// (`"foundationModels"` / `"claudeCLI"`) — never `.auto`. Forced Foundation Models falls
/// back to `claude -p` when the model isn't available here; `.auto` picks the same way.
public func resolveProviderKind(preference: ProviderPreference, foundationAvailable: Bool) -> String {
  switch preference {
  case .auto, .foundationModels:
    return foundationAvailable ? "foundationModels" : "claudeCLI"
  case .claudeCLI:
    return "claudeCLI"
  }
}

/// Resolve which prefs file to read: an explicit URL (tests), else the `PENSIEVE_PREFS`
/// env override (throwaway dev runs), else the real support-dir file. Tests always pass an
/// explicit URL, so the env is never consulted from a test — no process-global race under
/// Swift Testing's parallel execution.
private func resolvedPrefsURL(_ explicit: URL?) -> URL {
  if let explicit { return explicit }
  if let override = ProcessInfo.processInfo.environment["PENSIEVE_PREFS"] {
    return URL(fileURLWithPath: override)
  }
  return PensievePaths.preferencesURL()
}

/// Local-first, preference-aware selection. All existing call sites keep calling this
/// argument-free; the defaulted param exists for test injection.
public func makeDefaultLLMProvider(prefsURL: URL? = nil) -> any LLMProvider {
  let kind = defaultProviderKind(prefsURL: prefsURL)
  #if canImport(FoundationModels)
  if #available(macOS 26.0, *), kind == "foundationModels" {
    return FoundationModelsProvider()
  }
  #endif
  return ClaudeCLIProvider()
}

/// Pure, testable readout of which provider `makeDefaultLLMProvider` would select, honoring
/// the persisted preference + on-device availability.
public func defaultProviderKind(prefsURL: URL? = nil) -> String {
  let preference = Preferences.read(from: resolvedPrefsURL(prefsURL))
  return resolveProviderKind(preference: preference, foundationAvailable: foundationModelsIsSelectable())
}
