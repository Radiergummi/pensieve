import Foundation
import Testing
@testable import PensieveKit

@Test func flavorDefaultsAndSuffixes() {
  #expect(CloudFlavor.anthropic.defaultBaseURL == "https://api.anthropic.com")
  #expect(CloudFlavor.openAICompatible.defaultBaseURL == "https://api.openai.com/v1")
  #expect(CloudFlavor.anthropic.completionSuffix == "/v1/messages")
  #expect(CloudFlavor.openAICompatible.completionSuffix == "/chat/completions")
  #expect(CloudFlavor.anthropic.modelsSuffix == "/v1/models")
  #expect(CloudFlavor.openAICompatible.modelsSuffix == "/models")
}

@Test func configIsUsableRequiresBaseAndModel() {
  #expect(CloudConfig(flavor: .anthropic, baseURL: "https://x", model: "m").isUsable)
  #expect(!CloudConfig(flavor: .anthropic, baseURL: "", model: "m").isUsable)
  #expect(!CloudConfig(flavor: .anthropic, baseURL: "https://x", model: "").isUsable)
}

private func bodyJSON(_ request: URLRequest) -> [String: Any] {
  guard let data = request.httpBody,
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
  return obj
}

@Test func anthropicCompletionRequestShape() throws {
  let cfg = CloudConfig(flavor: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-x")
  let request = try CloudHTTP.buildCompletionRequest(config: cfg, apiKey: "sk-ant", prompt: "hi")
  #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
  #expect(request.httpMethod == "POST")
  #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
  #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
  let body = bodyJSON(request)
  #expect(body["model"] as? String == "claude-x")
  #expect(body["max_tokens"] as? Int == 1024)
  let messages = body["messages"] as? [[String: Any]]
  #expect(messages?.first?["role"] as? String == "user")
  #expect(messages?.first?["content"] as? String == "hi")
}

@Test func openAICompletionRequestShape() throws {
  let cfg = CloudConfig(flavor: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-x")
  let request = try CloudHTTP.buildCompletionRequest(config: cfg, apiKey: "sk-oai", prompt: "hi")
  #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-oai")
  #expect(bodyJSON(request)["model"] as? String == "gpt-x")
}

@Test func modelsRequestPathsAvoidDoubleV1() throws {
  let anthropicRequest = try CloudHTTP.buildModelsRequest(
    config: CloudConfig(flavor: .anthropic, baseURL: "https://api.anthropic.com", model: "m"), apiKey: "k")
  #expect(anthropicRequest.url?.absoluteString == "https://api.anthropic.com/v1/models")
  #expect(anthropicRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
  #expect(anthropicRequest.httpMethod == "GET")
  let openAIRequest = try CloudHTTP.buildModelsRequest(
    config: CloudConfig(flavor: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "m"), apiKey: "k")
  #expect(openAIRequest.url?.absoluteString == "https://api.openai.com/v1/models")
  #expect(openAIRequest.value(forHTTPHeaderField: "Authorization") == "Bearer k")
}

@Test func trailingSlashInBaseIsNotDoubled() throws {
  let completionRequest = try CloudHTTP.buildCompletionRequest(
    config: CloudConfig(flavor: .anthropic, baseURL: "https://api.anthropic.com/", model: "m"),
    apiKey: "k", prompt: "hi")
  #expect(completionRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
}

@Test func parseAnthropicAndOpenAICompletions() throws {
  let anthropicData = Data(#"{"content":[{"type":"text","text":"hello"}]}"#.utf8)
  #expect(try CloudHTTP.parseCompletion(flavor: .anthropic, anthropicData) == "hello")
  let openAIData = Data(#"{"choices":[{"message":{"role":"assistant","content":"hi there"}}]}"#.utf8)
  #expect(try CloudHTTP.parseCompletion(flavor: .openAICompatible, openAIData) == "hi there")
}

@Test func parseCompletionThrowsOnMalformed() {
  #expect(throws: LLMError.self) {
    try CloudHTTP.parseCompletion(flavor: .anthropic, Data("{}".utf8))
  }
}

@Test func parseModelListSortsIDs() throws {
  let data = Data(#"{"data":[{"id":"zeta"},{"id":"alpha"}]}"#.utf8)
  #expect(try CloudHTTP.parseModelList(data) == ["alpha", "zeta"])
}

@Test func parseModelListThrowsOnMalformed() {
  #expect(throws: LLMError.self) { try CloudHTTP.parseModelList(Data("[]".utf8)) }
}

private func httpResponse(_ status: Int) -> HTTPURLResponse {
  HTTPURLResponse(url: URL(string: "https://x")!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

@Test func completeReturnsParsedText() async throws {
  let cfg = CloudConfig(flavor: .anthropic, baseURL: "https://api.anthropic.com", model: "m")
  let provider = CloudLLMProvider(config: cfg, apiKey: "k") { _ in
    (Data(#"{"content":[{"text":"done"}]}"#.utf8), httpResponse(200))
  }
  let out = try await provider.complete(prompt: "hi")
  #expect(out == "done")
}

@Test func completeThrowsWithSnippetOnNon2xx() async {
  let cfg = CloudConfig(flavor: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "m")
  let provider = CloudLLMProvider(config: cfg, apiKey: "k") { _ in
    (Data(#"{"error":"bad key"}"#.utf8), httpResponse(401))
  }
  await #expect(throws: LLMError.self) { try await provider.complete(prompt: "hi") }
}

@Test func listModelsReturnsSortedIDs() async throws {
  let cfg = CloudConfig(flavor: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "m")
  let ids = try await CloudLLMProvider.listModels(config: cfg, apiKey: "k") { _ in
    (Data(#"{"data":[{"id":"b"},{"id":"a"}]}"#.utf8), httpResponse(200))
  }
  #expect(ids == ["a", "b"])
}

@Test func listModelsThrowsOnNon2xx() async {
  let cfg = CloudConfig(flavor: .anthropic, baseURL: "https://api.anthropic.com", model: "m")
  await #expect(throws: LLMError.self) {
    _ = try await CloudLLMProvider.listModels(config: cfg, apiKey: "k") { _ in
      (Data("nope".utf8), httpResponse(403))
    }
  }
}

@Test func isLocalEndpointDetectsLoopback() {
  #expect(CloudConfig(flavor: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "m").isLocalEndpoint)
  #expect(CloudConfig(flavor: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1", model: "m").isLocalEndpoint)
  #expect(CloudConfig(flavor: .openAICompatible, baseURL: "http://[::1]:11434/v1", model: "m").isLocalEndpoint)
  #expect(!CloudConfig(flavor: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "m").isLocalEndpoint)
  #expect(!CloudConfig(flavor: .openAICompatible, baseURL: "", model: "m").isLocalEndpoint)
}
