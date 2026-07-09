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
}

/// Pure HTTP request building + response parsing for the cloud flavors. No I/O — every function
/// is deterministic and unit-tested. `CloudLLMProvider` composes these with an injected transport.
public enum CloudHTTP {
  static let anthropicVersion = "2023-06-01"
  static let maxTokens = 1024

  private struct Message: Encodable { let role: String; let content: String }
  private struct AnthropicBody: Encodable { let model: String; let max_tokens: Int; let messages: [Message] }
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
        AnthropicBody(model: config.model, max_tokens: maxTokens, messages: [message]))
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

  private struct AnthropicResp: Decodable { struct Block: Decodable { let text: String? }; let content: [Block] }
  private struct OpenAIResp: Decodable {
    struct Choice: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
    let choices: [Choice]
  }
  private struct ModelsResp: Decodable { struct M: Decodable { let id: String }; let data: [M] }

  public static func parseCompletion(flavor: CloudFlavor, _ data: Data) throws -> String {
    switch flavor {
    case .anthropic:
      guard let text = (try? JSONDecoder().decode(AnthropicResp.self, from: data))?
        .content.compactMap({ $0.text }).first else {
        throw LLMError.providerFailed("no text in Anthropic response")
      }
      return text
    case .openAICompatible:
      guard let text = (try? JSONDecoder().decode(OpenAIResp.self, from: data))?
        .choices.first?.message.content else {
        throw LLMError.providerFailed("no content in OpenAI response")
      }
      return text
    }
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
    Log.llm.debug("LLM prompt dispatched (len=\(prompt.count, privacy: .public), provider=cloud/\(self.config.flavor.rawValue, privacy: .public))")
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
      let snippet = String(decoding: data, as: UTF8.self)
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
