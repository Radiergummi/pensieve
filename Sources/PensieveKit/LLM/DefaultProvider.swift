import Foundation

/// True when Foundation Models is compiled in, requires macOS 26+, and the on-device
/// model reports itself available on this machine. Shared by `makeDefaultLLMProvider()`
/// and `defaultProviderKind()` so the two can never disagree.
private func foundationModelsIsSelectable() -> Bool {
  #if canImport(FoundationModels)
  if #available(macOS 26.0, *) {
    return FoundationModelsProbe.availabilityDescription() == "available"
  }
  #endif
  return false
}

/// Local-first selection: Foundation Models when available on this machine, else `claude -p`.
public func makeDefaultLLMProvider() -> any LLMProvider {
  #if canImport(FoundationModels)
  if #available(macOS 26.0, *), foundationModelsIsSelectable() {
    return FoundationModelsProvider()
  }
  #endif
  return ClaudeCLIProvider()
}

/// Pure, testable readout of which provider `makeDefaultLLMProvider()` would select.
public func defaultProviderKind() -> String {
  foundationModelsIsSelectable() ? "foundationModels" : "claudeCLI"
}
