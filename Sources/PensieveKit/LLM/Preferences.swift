import Foundation

/// The user's LLM-provider choice. `.auto` = local-first (Foundation Models when available, else
/// `claude -p`). `.cloud` selects the HTTP provider (app-only; falls back to local when unconfigured).
/// Raw values are the stable on-disk strings persisted in UserDefaults.
public enum ProviderPreference: String, Sendable, Codable {
  case auto
  case foundationModels
  case claudeCLI
  case cloud
}

/// Reads the provider selection from a UserDefaults domain. Pure over its argument, so tests inject
/// a throwaway `UserDefaults(suiteName:)`. A missing or unknown value ⇒ `.auto`.
public enum ProviderSettings {
  public static func selection(from defaults: UserDefaults) -> ProviderPreference {
    guard let raw = defaults.string(forKey: PensieveDefaults.llmProviderKey),
          let preference = ProviderPreference(rawValue: raw) else { return .auto }
    return preference
  }
}
