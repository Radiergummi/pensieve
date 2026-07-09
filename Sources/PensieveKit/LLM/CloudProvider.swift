import Foundation

/// Which HTTP API dialect a cloud provider speaks. Raw values are the stable on-disk strings.
public enum CloudFlavor: String, Sendable, Codable, CaseIterable {
  case anthropic
  case openAICompatible

  /// Default host root. Anthropic carries the version in each path (`/v1/...`); the OpenAI
  /// convention puts `/v1` in the base, so paths omit it. See `completionSuffix`/`modelsSuffix`.
  public var defaultBaseURL: String {
    switch self {
    case .anthropic: return "https://api.anthropic.com"
    case .openAICompatible: return "https://api.openai.com/v1"
    }
  }

  /// Path appended to `baseURL` for a completion. Never synthesizes/strips `/v1` — the base
  /// already encodes where the version segment lives, so a user-edited gateway base passes through.
  public var completionSuffix: String {
    switch self {
    case .anthropic: return "/v1/messages"
    case .openAICompatible: return "/chat/completions"
    }
  }

  /// Path appended to `baseURL` to list models.
  public var modelsSuffix: String {
    switch self {
    case .anthropic: return "/v1/models"
    case .openAICompatible: return "/models"
    }
  }
}

/// Non-secret cloud provider config (the API key lives in the Keychain, never here).
public struct CloudConfig: Sendable, Equatable {
  public var flavor: CloudFlavor
  public var baseURL: String
  public var model: String
  public init(flavor: CloudFlavor, baseURL: String, model: String) {
    self.flavor = flavor
    self.baseURL = baseURL
    self.model = model
  }
  public var isUsable: Bool { !baseURL.isEmpty && !model.isEmpty }
}
