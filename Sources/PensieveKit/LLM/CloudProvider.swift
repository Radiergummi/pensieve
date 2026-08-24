import Foundation
import os

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

  /// True when the base URL host is a loopback address. Lets a keyless local server (e.g. Ollama)
  /// count as configured without weakening the remote-vendor key requirement.
  public var isLocalEndpoint: Bool {
    guard let url = URL(string: baseURL), let host = url.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
  }

  /// The persisted cloud config. Every field falls back to what the Settings UI *displays* when the
  /// user hasn't touched it: an unset flavor is `.anthropic` (the picker's default) and an empty base
  /// URL is that flavor's default. This is load-bearing — `@AppStorage` never writes its own default,
  /// so a user who selects "Cloud (API)" and keeps the default vendor leaves `cloudFlavor` unset;
  /// treating that as "no config" degraded cloud to local while Settings still said "Cloud (API)".
  /// Not usable on its own: `isUsable` still requires a model, and the caller still requires a key.
  public static func fromDefaults(_ defaults: UserDefaults) -> CloudConfig {
    let flavor = (defaults.string(forKey: PensieveDefaults.cloudFlavorKey)).flatMap(CloudFlavor.init(rawValue:)) ?? .anthropic
    let stored = defaults.string(forKey: PensieveDefaults.cloudBaseURLKey) ?? ""
    return CloudConfig(flavor: flavor,
                       baseURL: stored.isEmpty ? flavor.defaultBaseURL : stored,
                       model: defaults.string(forKey: PensieveDefaults.cloudModelKey) ?? "")
  }
}

private struct Message: Encodable { let role: String; let content: String }

/// Lives at file scope, not nested in `CloudHTTP`, so its `CodingKeys` stays within the one-level
/// type-nesting limit.
private struct AnthropicBody: Encodable {
  let model: String; let maxTokens: Int; let messages: [Message]
  // `max_tokens` is the Anthropic API's wire key; the Swift property stays camelCase.
  enum CodingKeys: String, CodingKey { case model, messages, maxTokens = "max_tokens" }
}

/// Response shapes for `parseCompletion`/`parseModelList`. Lives at file scope, not nested in
/// `CloudHTTP`, so no type is more than one level deep.
///
/// `stopReason` is how the vendor says "I stopped because I hit `max_tokens`". Optional because a
/// gateway may omit it; absent is read as "not truncated", the same as any other reason.
private struct AnthropicResp: Decodable {
  struct Block: Decodable { let text: String? }
  let content: [Block]
  let stopReason: String?
  // `stop_reason` is the Anthropic API's wire key; the Swift property stays camelCase.
  enum CodingKeys: String, CodingKey { case content, stopReason = "stop_reason" }
}

/// Lives at file scope for the same reason as `AnthropicResp`. `Choice`/`OpenAIMessage` are hoisted
/// out too (rather than nested in `OpenAIResp`) so neither exceeds the one-level nesting limit.
private struct OpenAIMessage: Decodable { let content: String }
private struct OpenAIChoice: Decodable {
  let message: OpenAIMessage
  let finishReason: String?
  // `finish_reason` is the OpenAI API's wire key; the Swift property stays camelCase.
  enum CodingKeys: String, CodingKey { case message, finishReason = "finish_reason" }
}
private struct OpenAIResp: Decodable { let choices: [OpenAIChoice] }

/// Lives at file scope for the same reason as `AnthropicResp`. `ModelEntry` names what it is: one
/// entry in the `/models` list response. The wire key `data` and field `id` are unchanged.
private struct ModelsResp: Decodable {
  struct ModelEntry: Decodable { let id: String }
  let data: [ModelEntry]
}

/// Pure HTTP request building + response parsing for the cloud flavors. No I/O — every function
/// is deterministic and unit-tested. `CloudLLMProvider` composes these with an injected transport.
public enum CloudHTTP {
  static let anthropicVersion = "2023-06-01"
  static let maxTokens = 1024

  private struct OpenAIBody: Encodable { let model: String; let messages: [Message] }

  /// Trim exactly one trailing slash so `base + suffix` never doubles the separator.
  private static func joined(_ base: String, _ suffix: String) throws -> URL {
    let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
    guard let url = URL(string: trimmed + suffix) else {
      throw LLMError.providerFailed("bad URL: \(trimmed + suffix)")
    }
    return url
  }

  private static func applyAuth(_ request: inout URLRequest, flavor: CloudFlavor, apiKey: String) {
    switch flavor {
    case .anthropic:
      request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
      request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
    case .openAICompatible:
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
  }

  public static func buildCompletionRequest(config: CloudConfig, apiKey: String, prompt: String) throws -> URLRequest {
    var request = URLRequest(url: try joined(config.baseURL, config.flavor.completionSuffix))
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    applyAuth(&request, flavor: config.flavor, apiKey: apiKey)
    let message = Message(role: "user", content: prompt)
    switch config.flavor {
    case .anthropic:
      request.httpBody = try JSONEncoder().encode(
        AnthropicBody(model: config.model, maxTokens: maxTokens, messages: [message]))
    case .openAICompatible:
      request.httpBody = try JSONEncoder().encode(
        OpenAIBody(model: config.model, messages: [message]))
    }
    return request
  }

  public static func buildModelsRequest(config: CloudConfig, apiKey: String) throws -> URLRequest {
    var request = URLRequest(url: try joined(config.baseURL, config.flavor.modelsSuffix))
    request.httpMethod = "GET"
    request.timeoutInterval = 120
    applyAuth(&request, flavor: config.flavor, apiKey: apiKey)
    return request
  }

  /// Parses a completion, **throwing when the model was cut off at `maxTokens`**.
  ///
  /// A truncated completion is not a shorter answer, it is half a sentence — and every caller here
  /// stores what it gets: narration is written to the node and to the narration cache, so one
  /// truncated reply is cached as if complete and served from then on. Nothing downstream can tell
  /// the difference after the fact, so the only place to catch it is here, where the vendor is still
  /// telling us. Throwing means no narration rather than a mutilated one, and the deterministic
  /// fallback summary takes over — the honest outcome.
  public static func parseCompletion(flavor: CloudFlavor, _ data: Data) throws -> String {
    switch flavor {
    case .anthropic:
      guard let response = try? JSONDecoder().decode(AnthropicResp.self, from: data),
            let text = response.content.compactMap({ $0.text }).first else {
        throw LLMError.providerFailed("no text in Anthropic response")
      }
      try refuseTruncated(response.stopReason, truncatedValue: "max_tokens")
      return text
    case .openAICompatible:
      guard let choice = (try? JSONDecoder().decode(OpenAIResp.self, from: data))?.choices.first else {
        throw LLMError.providerFailed("no content in OpenAI response")
      }
      try refuseTruncated(choice.finishReason, truncatedValue: "length")
      return choice.message.content
    }
  }

  /// Throws when the vendor's stop/finish reason says the output hit the token ceiling.
  private static func refuseTruncated(_ reason: String?, truncatedValue: String) throws {
    guard reason == truncatedValue else { return }
    Log.llm.error("Cloud completion truncated at maxTokens=\(maxTokens, privacy: .public); discarding")
    throw LLMError.providerFailed("completion truncated at maxTokens=\(maxTokens)")
  }

  public static func parseModelList(_ data: Data) throws -> [String] {
    guard let resp = try? JSONDecoder().decode(ModelsResp.self, from: data) else {
      throw LLMError.providerFailed("model list not parseable")
    }
    return resp.data.map { $0.id }.sorted()
  }
}

/// App-only cloud provider: prompt in / text out over HTTP. Best-effort narration, outside the
/// trust gate. Only `complete` is implemented; structured methods inherit the protocol defaults.
public struct CloudLLMProvider: LLMProvider {
  public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  let config: CloudConfig
  let apiKey: String
  let transport: Transport

  public init(config: CloudConfig, apiKey: String,
              transport: @escaping Transport = CloudLLMProvider.urlSessionTransport) {
    self.config = config
    self.apiKey = apiKey
    self.transport = transport
  }

  public func complete(prompt: String) async throws -> String {
    let flavorName = config.flavor.rawValue
    Log.llm.debug("LLM prompt dispatched (len=\(prompt.count, privacy: .public), provider=cloud/\(flavorName, privacy: .public))")
    let request = try CloudHTTP.buildCompletionRequest(config: config, apiKey: apiKey, prompt: prompt)
    let (data, response) = try await transport(request)
    try Self.ensure2xx(response, data)
    let result = try CloudHTTP.parseCompletion(flavor: config.flavor, data)
    Log.llm.debug("LLM completion received (len=\(result.count, privacy: .public))")
    return result
  }

  public static func listModels(config: CloudConfig, apiKey: String,
                                transport: @escaping Transport = CloudLLMProvider.urlSessionTransport)
    async throws -> [String] {
    let request = try CloudHTTP.buildModelsRequest(config: config, apiKey: apiKey)
    let (data, response) = try await transport(request)
    try ensure2xx(response, data)
    return try CloudHTTP.parseModelList(data)
  }

  private static func ensure2xx(_ response: HTTPURLResponse, _ data: Data) throws {
    guard (200..<300).contains(response.statusCode) else {
      let snippet = (String(bytes: data, encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)
      Log.llm.error("Cloud HTTP \(response.statusCode, privacy: .public): \(String(snippet), privacy: .public)")
      throw LLMError.providerFailed("HTTP \(response.statusCode): \(snippet)")
    }
  }

  /// Default transport. Guard-casts `URLResponse` to `HTTPURLResponse` (never a force-cast).
  public static let urlSessionTransport: Transport = { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw LLMError.providerFailed("non-HTTP response")
    }
    return (data, http)
  }
}
