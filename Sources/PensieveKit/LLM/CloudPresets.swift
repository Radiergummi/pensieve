import Foundation

/// A known cloud vendor with a pre-filled base URL. Pure UI sugar over `CloudConfig` — presets are
/// NOT persisted; the Settings picker derives its selection from the stored (flavor, baseURL).
public struct CloudPreset: Sendable, Equatable, Identifiable {
  public let id: String          // stable slug, also the Keychain account
  public let displayName: String // proper name — never localized
  public let flavor: CloudFlavor
  public let baseURL: String
  public init(id: String, displayName: String, flavor: CloudFlavor, baseURL: String) {
    self.id = id; self.displayName = displayName; self.flavor = flavor; self.baseURL = baseURL
  }
}

public enum CloudPresets {
  /// Shipping vendors, in picker order. All OpenAI-compatible except Anthropic.
  public static let all: [CloudPreset] = [
    CloudPreset(id: "openai", displayName: "OpenAI", flavor: .openAICompatible, baseURL: "https://api.openai.com/v1"),
    CloudPreset(id: "anthropic", displayName: "Anthropic", flavor: .anthropic, baseURL: "https://api.anthropic.com"),
    CloudPreset(id: "gemini", displayName: "Google Gemini", flavor: .openAICompatible, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"),
    CloudPreset(id: "groq", displayName: "Groq", flavor: .openAICompatible, baseURL: "https://api.groq.com/openai/v1"),
    CloudPreset(id: "openrouter", displayName: "OpenRouter", flavor: .openAICompatible, baseURL: "https://openrouter.ai/api/v1"),
    CloudPreset(id: "mistral", displayName: "Mistral", flavor: .openAICompatible, baseURL: "https://api.mistral.ai/v1"),
    CloudPreset(id: "ollama", displayName: "Ollama (local)", flavor: .openAICompatible, baseURL: "http://localhost:11434/v1"),
  ]

  /// The preset whose (flavor, baseURL) matches exactly, else nil ⇒ "Custom".
  public static func match(flavor: CloudFlavor, baseURL: String) -> CloudPreset? {
    all.first { $0.flavor == flavor && $0.baseURL == baseURL }
  }

  /// Keychain account for this vendor identity: the matching preset id, else a per-flavor custom
  /// slot. Computed identically by the app (write/read) and AppModel (read) so keys never collide
  /// across vendors that share a flavor.
  public static func keychainAccount(flavor: CloudFlavor, baseURL: String) -> String {
    match(flavor: flavor, baseURL: baseURL)?.id ?? "custom.\(flavor.rawValue)"
  }
}
