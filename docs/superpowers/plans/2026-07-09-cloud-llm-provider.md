# Cloud / API LLM Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an app-only cloud (HTTP API) `LLMProvider` — Anthropic + OpenAI-compatible flavors, Keychain-stored key, model list fetched from the provider — as a fourth provider option for the app's "Last Work Done" narration, and retire `preferences.json` in favor of UserDefaults read cross-process by the CLI/daemon.

**Architecture:** A pure, testable `CloudLLMProvider` (flavor enum + pure request/response builders + an injected transport) mirrors the existing `ClaudeCLIProvider`. Provider selection + non-secret cloud config move to UserDefaults (`me.mazetti.pensieve` domain, read by the CLI/daemon via `UserDefaults(suiteName:)` since the app is not sandboxed); the API key lives in the Keychain, reachable only by the app, so cloud stays app-only and the trust-gated extraction stays on-device. The pure resolver/builders are unit-tested; the two OS boundaries (URLSession, Keychain) are thin and injected.

**Tech Stack:** Swift 6, Swift Testing, Foundation `URLSession`, `Security` framework (`SecItem`), SwiftUI (`@AppStorage`), XcodeGen/Xcode for the app bundle.

## Global Constraints

- **Swift only. No Python, ever.**
- **SQLiteData predicates use `.eq(x)`, not `== x`.** (Not touched here, but repo-wide.)
- **No shared mutable `static ISO8601DateFormatter`** (Swift 6 concurrency) — use a local instance / `Date.ISO8601FormatStyle`.
- **The trust gate is sacred and untouched.** Cloud serves only best-effort narration (outside the cited trust gate). No schema, capture, or entitlement change.
- **App bundle id / UserDefaults domain:** `me.mazetti.pensieve`.
- **Keychain generic-password service:** `com.pensieve.cloud-llm`; `account = flavor.rawValue`.
- **The API key is never written to UserDefaults, a plist, JSON, or a log.** Keychain only.
- **`swift test` compiles PensieveKit + the `pensieve` CLI only** (the app is an Xcode-only target). Kit/CLI tasks verify with `./scripts/test.sh`; app tasks verify with `xcodegen generate && xcodebuild` + a non-blocking smoke-launch of the inner binary.
- **App build:** `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`; bundle at `./.build-xcode/Build/Products/Debug/Pensieve.app`.
- **Localization: chrome only.** New app-UI strings get German (`de`) values by hand in `Localizable.xcstrings` (xcodebuild does NOT auto-populate keys). Provider/vendor names stay English.
- **Commit trailers:** keep the repo's `Co-Authored-By:` + `Claude-Session:` trailers on every commit. Commit messages contain no backticks (they get shell-executed under `-m`).

---

## File Structure

**PensieveKit (SwiftPM, tested)**
- `Sources/PensieveKit/LLM/CloudProvider.swift` (new) — `CloudFlavor`, `CloudConfig`, `CloudLLMProvider` + pure builders/parsers.
- `Sources/PensieveKit/Support/PensieveDefaults.swift` (new) — UserDefaults domain + key constants + `shared()`.
- `Sources/PensieveKit/Support/KeychainSecretStore.swift` (new) — thin `SecItem` generic-password wrapper.
- `Sources/PensieveKit/LLM/Preferences.swift` (modify) — keep `ProviderPreference` (+`.cloud`), delete the `Preferences` json type, add `ProviderSettings.selection(from:)`.
- `Sources/PensieveKit/LLM/DefaultProvider.swift` (modify) — rework `resolveProviderKind` (+`cloudConfigured`) and `makeDefaultLLMProvider(defaults:cloudConfig:apiKey:)`; drop `defaultProviderKind` / `resolvedPrefsURL` / `PENSIEVE_PREFS`.
- `Sources/PensieveKit/Support/PensievePaths.swift` (modify) — remove `preferencesURL()`.

**pensieve CLI (SwiftPM, tested)**
- `Sources/pensieve/Commands/{Ingest,Digest,Sync}.swift` (modify) — pass `defaults: PensieveDefaults.shared()`.

**PensieveApp (Xcode target, build + smoke only)**
- `Sources/PensieveApp/AppModel.swift` (modify) — factory wiring + cloud-aware `providerKind`.
- `Sources/PensieveApp/PensieveApp.swift` (modify) — remove `Stores.preferencesURL`.
- `Sources/PensieveApp/SettingsView.swift` (modify) — cloud subsection (flavor/base-URL/key/model+Fetch).
- `Sources/PensieveApp/Localizable.xcstrings` (modify) — new German keys.
- `project.yml` (modify) — remove the dead `PENSIEVE_PREFS` scheme env var.

**Tests**
- `Tests/PensieveKitTests/CloudProviderTests.swift` (new).
- `Tests/PensieveKitTests/PreferencesTests.swift` (rewrite).
- `Tests/PensieveKitTests/DefaultProviderTests.swift` (rewrite).

---

## Task 1: `CloudFlavor` + `CloudConfig` value types

**Files:**
- Create: `Sources/PensieveKit/LLM/CloudProvider.swift`
- Test: `Tests/PensieveKitTests/CloudProviderTests.swift`

**Interfaces:**
- Produces:
  - `public enum CloudFlavor: String, Sendable, Codable, CaseIterable { case anthropic; case openAICompatible }` with `var defaultBaseURL: String`, `var completionSuffix: String`, `var modelsSuffix: String`.
  - `public struct CloudConfig: Sendable, Equatable { public var flavor: CloudFlavor; public var baseURL: String; public var model: String; public init(flavor:baseURL:model:); public var isUsable: Bool }`

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/CloudProviderTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter CloudProviderTests`
Expected: FAIL — `cannot find 'CloudFlavor' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/PensieveKit/LLM/CloudProvider.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter CloudProviderTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/LLM/CloudProvider.swift Tests/PensieveKitTests/CloudProviderTests.swift
git commit -m "feat(llm): add CloudFlavor and CloudConfig value types"
```

---

## Task 2: Cloud request builders + response/model-list parsers (pure)

**Files:**
- Modify: `Sources/PensieveKit/LLM/CloudProvider.swift`
- Test: `Tests/PensieveKitTests/CloudProviderTests.swift`

**Interfaces:**
- Consumes: `CloudFlavor`, `CloudConfig`, `LLMError` (existing, from `LLMProvider.swift`).
- Produces (all `static` on `CloudLLMProvider`, but define them now as `enum CloudHTTP` free functions so they exist before the provider struct):
  - `static func buildCompletionRequest(config: CloudConfig, apiKey: String, prompt: String) throws -> URLRequest`
  - `static func buildModelsRequest(config: CloudConfig, apiKey: String) throws -> URLRequest`
  - `static func parseCompletion(flavor: CloudFlavor, _ data: Data) throws -> String`
  - `static func parseModelList(_ data: Data) throws -> [String]`

We put these as `static` members of an `enum CloudHTTP` in the same file (Task 3's `CloudLLMProvider` calls them). This keeps the provider struct thin.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/CloudProviderTests.swift`:

```swift
private func bodyJSON(_ request: URLRequest) -> [String: Any] {
  guard let data = request.httpBody,
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
  return obj
}

@Test func anthropicCompletionRequestShape() throws {
  let cfg = CloudConfig(flavor: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-x")
  let r = try CloudHTTP.buildCompletionRequest(config: cfg, apiKey: "sk-ant", prompt: "hi")
  #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages")
  #expect(r.httpMethod == "POST")
  #expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
  #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
  let body = bodyJSON(r)
  #expect(body["model"] as? String == "claude-x")
  #expect(body["max_tokens"] as? Int == 1024)
  let messages = body["messages"] as? [[String: Any]]
  #expect(messages?.first?["role"] as? String == "user")
  #expect(messages?.first?["content"] as? String == "hi")
}

@Test func openAICompletionRequestShape() throws {
  let cfg = CloudConfig(flavor: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-x")
  let r = try CloudHTTP.buildCompletionRequest(config: cfg, apiKey: "sk-oai", prompt: "hi")
  #expect(r.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
  #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-oai")
  #expect(bodyJSON(r)["model"] as? String == "gpt-x")
}

@Test func modelsRequestPathsAvoidDoubleV1() throws {
  let a = try CloudHTTP.buildModelsRequest(
    config: CloudConfig(flavor: .anthropic, baseURL: "https://api.anthropic.com", model: "m"), apiKey: "k")
  #expect(a.url?.absoluteString == "https://api.anthropic.com/v1/models")
  #expect(a.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
  #expect(a.httpMethod == "GET")
  let o = try CloudHTTP.buildModelsRequest(
    config: CloudConfig(flavor: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "m"), apiKey: "k")
  #expect(o.url?.absoluteString == "https://api.openai.com/v1/models")
  #expect(o.value(forHTTPHeaderField: "Authorization") == "Bearer k")
}

@Test func trailingSlashInBaseIsNotDoubled() throws {
  let r = try CloudHTTP.buildCompletionRequest(
    config: CloudConfig(flavor: .anthropic, baseURL: "https://api.anthropic.com/", model: "m"),
    apiKey: "k", prompt: "hi")
  #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages")
}

@Test func parseAnthropicAndOpenAICompletions() throws {
  let a = Data(#"{"content":[{"type":"text","text":"hello"}]}"#.utf8)
  #expect(try CloudHTTP.parseCompletion(flavor: .anthropic, a) == "hello")
  let o = Data(#"{"choices":[{"message":{"role":"assistant","content":"hi there"}}]}"#.utf8)
  #expect(try CloudHTTP.parseCompletion(flavor: .openAICompatible, o) == "hi there")
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter CloudProviderTests`
Expected: FAIL — `cannot find 'CloudHTTP' in scope`.

- [ ] **Step 3: Write the implementation**

Append to `Sources/PensieveKit/LLM/CloudProvider.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter CloudProviderTests`
Expected: PASS (all Task 1 + Task 2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/LLM/CloudProvider.swift Tests/PensieveKitTests/CloudProviderTests.swift
git commit -m "feat(llm): add pure cloud request builders and response parsers"
```

---

## Task 3: `CloudLLMProvider` (complete + listModels over an injected transport)

**Files:**
- Modify: `Sources/PensieveKit/LLM/CloudProvider.swift`
- Test: `Tests/PensieveKitTests/CloudProviderTests.swift`

**Interfaces:**
- Consumes: `CloudHTTP`, `CloudConfig`, `LLMProvider` protocol + its default structured methods (from `LLMProvider.swift`).
- Produces:
  - `public struct CloudLLMProvider: LLMProvider` with:
    - `public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)`
    - `public init(config: CloudConfig, apiKey: String, transport: @escaping Transport = CloudLLMProvider.urlSessionTransport)`
    - `public func complete(prompt: String) async throws -> String`
    - `public static func listModels(config: CloudConfig, apiKey: String, transport: @escaping Transport = CloudLLMProvider.urlSessionTransport) async throws -> [String]`
    - `public static let urlSessionTransport: Transport`

Conforms to `LLMProvider` with only `complete` — the structured `extractCandidates`/`classify*` methods inherit the protocol's JSON-decode defaults (never exercised: cloud is narration-only).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/CloudProviderTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter CloudProviderTests`
Expected: FAIL — `cannot find 'CloudLLMProvider' in scope`.

- [ ] **Step 3: Write the implementation**

Append to `Sources/PensieveKit/LLM/CloudProvider.swift`:

```swift
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
    let request = try CloudHTTP.buildCompletionRequest(config: config, apiKey: apiKey, prompt: prompt)
    let (data, response) = try await transport(request)
    try Self.ensure2xx(response, data)
    return try CloudHTTP.parseCompletion(flavor: config.flavor, data)
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter CloudProviderTests`
Expected: PASS (all cloud tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/LLM/CloudProvider.swift Tests/PensieveKitTests/CloudProviderTests.swift
git commit -m "feat(llm): add CloudLLMProvider with injected transport"
```

---

## Task 4: `KeychainSecretStore`

**Files:**
- Create: `Sources/PensieveKit/Support/KeychainSecretStore.swift`

**Interfaces:**
- Produces:
  - `public struct KeychainSecretStore: Sendable { public init(service: String = "com.pensieve.cloud-llm"); public func read(account: String) -> String?; public func write(_ secret: String, account: String); public func delete(account: String) }`

No unit test: `SecItem` hits the real login keychain (prompt-prone, flaky, would pollute the developer's keychain). Verified by hand in the built app. The task deliverable is the file compiling into PensieveKit.

- [ ] **Step 1: Write the implementation**

Create `Sources/PensieveKit/Support/KeychainSecretStore.swift`:

```swift
import Foundation
import Security

/// Thin generic-password wrapper. App-only (the daemon can't answer a Keychain prompt). Errors are
/// best-effort/swallowed: a failed read ⇒ nil ⇒ the cloud provider falls back to local. Never logs
/// the secret.
public struct KeychainSecretStore: Sendable {
  private let service: String
  public init(service: String = "com.pensieve.cloud-llm") { self.service = service }

  public func read(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let secret = String(data: data, encoding: .utf8) else { return nil }
    return secret
  }

  /// Upserts the secret. An empty string deletes the item (so blanking the field clears the key).
  public func write(_ secret: String, account: String) {
    guard !secret.isEmpty else { delete(account: account); return }
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let data = Data(secret.utf8)
    let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var add = base
      add[kSecValueData as String] = data
      SecItemAdd(add as CFDictionary, nil)
    }
  }

  public func delete(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `./scripts/test.sh --filter CloudProviderTests`
Expected: PASS (the suite still builds; no new tests, but the package compiles with the new file).

- [ ] **Step 3: Commit**

```bash
git add Sources/PensieveKit/Support/KeychainSecretStore.swift
git commit -m "feat(support): add KeychainSecretStore generic-password wrapper"
```

---

## Task 5: Retire `preferences.json`; UserDefaults selection + factory rework (Kit + CLI)

This is the atomic refactor that must land together to keep `swift test` green: it adds the `.cloud` case (forcing the resolver's switch), removes the `Preferences` json type + `defaultProviderKind`, and updates every Kit/CLI caller and the two Kit test files.

**Files:**
- Create: `Sources/PensieveKit/Support/PensieveDefaults.swift`
- Modify: `Sources/PensieveKit/LLM/Preferences.swift`
- Modify: `Sources/PensieveKit/LLM/DefaultProvider.swift`
- Modify: `Sources/PensieveKit/Support/PensievePaths.swift` (remove `preferencesURL()`)
- Modify: `Sources/pensieve/Commands/Ingest.swift`, `Digest.swift`, `Sync.swift`
- Rewrite: `Tests/PensieveKitTests/PreferencesTests.swift`
- Rewrite: `Tests/PensieveKitTests/DefaultProviderTests.swift`

**Interfaces:**
- Consumes: `CloudConfig`, `CloudLLMProvider` (Tasks 1–3), `FoundationModelsProbe`, `FoundationModelsProvider`, `ClaudeCLIProvider`.
- Produces:
  - `public enum PensieveDefaults` — `appDomain`, `llmProviderKey`, `cloudFlavorKey`, `cloudBaseURLKey`, `cloudModelKey`, `static func shared() -> UserDefaults`.
  - `ProviderPreference` gains `case cloud` (raw `"cloud"`).
  - `public enum ProviderSettings { static func selection(from: UserDefaults) -> ProviderPreference }`.
  - `resolveProviderKind(preference:foundationAvailable:cloudConfigured:) -> String`.
  - `makeDefaultLLMProvider(defaults: UserDefaults = .standard, cloudConfig: CloudConfig? = nil, apiKey: String? = nil) -> any LLMProvider`.
- Removed: `Preferences` type, `defaultProviderKind`, `resolvedPrefsURL`, `PensievePaths.preferencesURL()`, the `PENSIEVE_PREFS` env read.

- [ ] **Step 1: Write/replace the failing tests**

Replace the ENTIRE contents of `Tests/PensieveKitTests/PreferencesTests.swift` with:

```swift
import Foundation
import Testing
@testable import PensieveKit

// MARK: ProviderSettings.selection

@Test func selectionAbsentAndUnknownReadAsAuto() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  #expect(ProviderSettings.selection(from: d) == .auto)                 // absent
  d.set("bogus", forKey: PensieveDefaults.llmProviderKey)
  #expect(ProviderSettings.selection(from: d) == .auto)                 // unknown value
}

@Test func selectionReadsKnownValues() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  for pref in [ProviderPreference.foundationModels, .claudeCLI, .cloud, .auto] {
    d.set(pref.rawValue, forKey: PensieveDefaults.llmProviderKey)
    #expect(ProviderSettings.selection(from: d) == pref)
  }
}

// MARK: resolveProviderKind

@Test func resolverAutoFollowsAvailability() {
  #expect(resolveProviderKind(preference: .auto, foundationAvailable: true, cloudConfigured: false) == "foundationModels")
  #expect(resolveProviderKind(preference: .auto, foundationAvailable: false, cloudConfigured: false) == "claudeCLI")
}

@Test func resolverForcedFoundationFallsBackWhenUnavailable() {
  #expect(resolveProviderKind(preference: .foundationModels, foundationAvailable: true, cloudConfigured: false) == "foundationModels")
  #expect(resolveProviderKind(preference: .foundationModels, foundationAvailable: false, cloudConfigured: false) == "claudeCLI")
}

@Test func resolverForcedClaudeAlwaysClaude() {
  #expect(resolveProviderKind(preference: .claudeCLI, foundationAvailable: true, cloudConfigured: false) == "claudeCLI")
  #expect(resolveProviderKind(preference: .claudeCLI, foundationAvailable: false, cloudConfigured: false) == "claudeCLI")
}

@Test func resolverCloudRequiresConfiguredElseLocal() {
  #expect(resolveProviderKind(preference: .cloud, foundationAvailable: false, cloudConfigured: true) == "cloud")
  #expect(resolveProviderKind(preference: .cloud, foundationAvailable: true, cloudConfigured: false) == "foundationModels")
  #expect(resolveProviderKind(preference: .cloud, foundationAvailable: false, cloudConfigured: false) == "claudeCLI")
}
```

Replace the ENTIRE contents of `Tests/PensieveKitTests/DefaultProviderTests.swift` with:

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func factoryFallsBackToLocalWithoutCloudInputs() {
  // An empty throwaway domain ⇒ selection == .auto ⇒ a usable local provider (never cloud).
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  let provider = makeDefaultLLMProvider(defaults: d)
  _ = provider   // FoundationModelsProvider or ClaudeCLIProvider — both usable LLMProviders

  let kind = resolveProviderKind(preference: .auto,
                                 foundationAvailable: FoundationModelsProbe.isAvailable(),
                                 cloudConfigured: false)
  #expect(kind == "foundationModels" || kind == "claudeCLI")
}

@Test func cloudSelectionWithoutKeyFallsBackToLocal() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  d.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  // .cloud selected but no cloudConfig/apiKey passed ⇒ not configured ⇒ local provider, no crash.
  let provider = makeDefaultLLMProvider(defaults: d)
  _ = provider
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter PreferencesTests`
Expected: FAIL — `cannot find 'ProviderSettings'` / `extra argument 'cloudConfigured'` / `PensieveDefaults`.

- [ ] **Step 3: Create `PensieveDefaults`**

Create `Sources/PensieveKit/Support/PensieveDefaults.swift`:

```swift
import Foundation

/// The single source of truth for the shared UserDefaults surface, so the app (writer) and the
/// CLI/daemon (cross-process reader) can't drift on domain or key names. The app is not sandboxed,
/// so its defaults persist to ~/Library/Preferences/me.mazetti.pensieve.plist, served by the
/// per-user cfprefsd; a same-user CLI reads that domain via `shared()`.
public enum PensieveDefaults {
  public static let appDomain = "me.mazetti.pensieve"
  public static let llmProviderKey = "llmProvider"
  public static let cloudFlavorKey = "cloudFlavor"
  public static let cloudBaseURLKey = "cloudBaseURL"
  public static let cloudModelKey = "cloudModel"

  /// The app's defaults domain, read from the CLI/daemon. Falls back to `.standard` if the suite
  /// can't be opened (never nil). The app itself uses `.standard` directly (its own domain).
  public static func shared() -> UserDefaults { UserDefaults(suiteName: appDomain) ?? .standard }
}
```

- [ ] **Step 4: Rework `Preferences.swift`**

Replace the ENTIRE contents of `Sources/PensieveKit/LLM/Preferences.swift` with:

```swift
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
```

- [ ] **Step 5: Rework `DefaultProvider.swift`**

Replace the ENTIRE contents of `Sources/PensieveKit/LLM/DefaultProvider.swift` with:

```swift
import Foundation

/// True when Foundation Models is compiled in, requires macOS 26+, and the on-device model reports
/// itself available on this machine. Shared by the factory and the resolver so they can't disagree.
private func foundationModelsIsSelectable() -> Bool {
  FoundationModelsProbe.isAvailable()
}

/// The whole provider decision as one pure function. Returns the concrete kind string
/// (`"foundationModels"` / `"claudeCLI"` / `"cloud"`) — never a preference case. Forced Foundation
/// Models and a `.cloud` selection that isn't configured both fall back to local-first the same way.
/// `cloudConfigured` is computed by the caller from config validity + key presence.
public func resolveProviderKind(preference: ProviderPreference,
                                foundationAvailable: Bool,
                                cloudConfigured: Bool) -> String {
  let local = foundationAvailable ? "foundationModels" : "claudeCLI"
  switch preference {
  case .cloud:
    return cloudConfigured ? "cloud" : local
  case .auto, .foundationModels:
    return local
  case .claudeCLI:
    return "claudeCLI"
  }
}

/// Preference-aware selection. The *selection* comes from an injected UserDefaults (app → `.standard`;
/// CLI/daemon → `PensieveDefaults.shared()`); the app additionally injects the cloud config + Keychain
/// key. Cloud is chosen only when selected AND fully configured, else it degrades to local-first.
public func makeDefaultLLMProvider(defaults: UserDefaults = .standard,
                                   cloudConfig: CloudConfig? = nil,
                                   apiKey: String? = nil) -> any LLMProvider {
  let preference = ProviderSettings.selection(from: defaults)
  let configured = (cloudConfig?.isUsable ?? false) && !(apiKey ?? "").isEmpty
  let kind = resolveProviderKind(preference: preference,
                                 foundationAvailable: foundationModelsIsSelectable(),
                                 cloudConfigured: configured)
  switch kind {
  case "cloud":
    return CloudLLMProvider(config: cloudConfig!, apiKey: apiKey!)
  case "foundationModels":
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) { return FoundationModelsProvider() }
    #endif
    return ClaudeCLIProvider()
  default:
    return ClaudeCLIProvider()
  }
}
```

- [ ] **Step 6: Remove `PensievePaths.preferencesURL()`**

In `Sources/PensieveKit/Support/PensievePaths.swift`, delete these lines (the doc comment + method):

```swift
  /// `~/Library/Application Support/Pensieve/preferences.json` — machine-local app/daemon
  /// settings (currently the LLM provider choice). NOT synced.
  public static func preferencesURL() -> URL {
    supportDirectory().appendingPathComponent("preferences.json")
  }
```

- [ ] **Step 7: Update the three CLI call sites**

`Sources/pensieve/Commands/Sync.swift` — change the provider line:

```swift
      provider: makeDefaultLLMProvider(defaults: PensieveDefaults.shared()),
```

`Sources/pensieve/Commands/Digest.swift` — change:

```swift
    let builder = SummaryBuilder(provider: makeDefaultLLMProvider(defaults: PensieveDefaults.shared()))
```

`Sources/pensieve/Commands/Ingest.swift` — change BOTH provider constructions:

```swift
    let provider = makeDefaultLLMProvider(defaults: PensieveDefaults.shared())
```

and

```swift
      let results = try await ExtractionRunner(db: db, provider: makeDefaultLLMProvider(defaults: PensieveDefaults.shared())).run()
```

- [ ] **Step 8: Run the FULL suite to verify green**

Run: `./scripts/test.sh`
Expected: PASS — all tests, including the reworked Preferences/DefaultProvider tests and the whole cloud suite. (If a stray reference to `Preferences`/`defaultProviderKind`/`preferencesURL` remains in the Kit or CLI, the build fails here — grep and fix: `grep -rn "Preferences\.\|defaultProviderKind\|preferencesURL" Sources/PensieveKit Sources/pensieve`.)

- [ ] **Step 9: Commit**

```bash
git add Sources/PensieveKit Sources/pensieve Tests/PensieveKitTests/PreferencesTests.swift Tests/PensieveKitTests/DefaultProviderTests.swift
git commit -m "refactor(llm): move provider selection to UserDefaults, add cloud kind, retire preferences.json"
```

---

## Task 6: App restore-to-compile + AppModel cloud wiring

Task 5 broke the Xcode app target (it referenced `Stores.preferencesURL`, `defaultProviderKind`, `Preferences`). This task restores the app build and wires the cloud-aware factory + cache key into `AppModel`, plus a minimal `.cloud` picker tag so `SettingsView` compiles. The full cloud UI lands in Task 7.

**Files:**
- Modify: `Sources/PensieveApp/PensieveApp.swift` (remove `Stores.preferencesURL`)
- Modify: `Sources/PensieveApp/AppModel.swift`
- Modify: `Sources/PensieveApp/SettingsView.swift` (minimal: switch to `@AppStorage`, add `.cloud` tag)
- Modify: `project.yml` (remove `PENSIEVE_PREFS`)

**Interfaces:**
- Consumes: `PensieveDefaults`, `ProviderSettings`, `resolveProviderKind`, `makeDefaultLLMProvider(defaults:cloudConfig:apiKey:)`, `CloudConfig`, `CloudFlavor`, `KeychainSecretStore`, `FoundationModelsProbe`.
- Produces (on `AppModel`): `private func cloudInputs() -> (CloudConfig?, String?)`, cloud-aware `providerKind`, `rebuildSummaryBuilder()` honoring cloud.

- [ ] **Step 1: Remove `Stores.preferencesURL`**

In `Sources/PensieveApp/PensieveApp.swift`, delete the `preferencesURL` computed property (lines 15–18):

```swift
  static var preferencesURL: URL {
    if let o = ProcessInfo.processInfo.environment["PENSIEVE_PREFS"] { return URL(fileURLWithPath: o) }
    return PensievePaths.preferencesURL()
  }
```

- [ ] **Step 2: Wire `AppModel`**

In `Sources/PensieveApp/AppModel.swift`, replace the provider-property block (currently lines ~136–148):

```swift
  private var summaryBuilder = SummaryBuilder(provider: makeDefaultLLMProvider())
  /// The provider kind the current `summaryBuilder` uses — folded into the narration cache key
  /// so a provider switch invalidates prose cached under the old provider.
  private var providerKind = defaultProviderKind()

  /// Rebuild the narration provider from the current persisted preference. Called by
  /// SettingsView after it writes a new ProviderPreference.
  func rebuildSummaryBuilder() {
    summaryBuilder = SummaryBuilder(provider: makeDefaultLLMProvider())
    providerKind = defaultProviderKind()
  }
```

with:

```swift
  // NOT lazy: rebuilt when the provider preference/config changes (SettingsView), so an in-session
  // switch takes effect on the next narration instead of requiring a relaunch. Bootstrapped cheaply
  // here; `init()` calls rebuildSummaryBuilder() to fold in any configured cloud provider.
  private var summaryBuilder = SummaryBuilder(provider: ClaudeCLIProvider())
  /// The provider kind the current `summaryBuilder` uses — folded into the narration cache key so a
  /// provider/model switch invalidates prose cached under the old provider.
  private var providerKind = "claudeCLI"

  /// Reads the app-side cloud inputs: config from UserDefaults, key from the Keychain. Returns
  /// (nil, nil) when no flavor is set.
  private func cloudInputs() -> (CloudConfig?, String?) {
    let d = UserDefaults.standard
    guard let raw = d.string(forKey: PensieveDefaults.cloudFlavorKey),
          let flavor = CloudFlavor(rawValue: raw) else { return (nil, nil) }
    let baseURL = d.string(forKey: PensieveDefaults.cloudBaseURLKey) ?? flavor.defaultBaseURL
    let model = d.string(forKey: PensieveDefaults.cloudModelKey) ?? ""
    let config = CloudConfig(flavor: flavor, baseURL: baseURL, model: model)
    let key = KeychainSecretStore().read(account: flavor.rawValue)
    return (config, key)
  }

  /// Rebuild the narration provider + its cache kind from the current UserDefaults selection + cloud
  /// inputs. The kind folds flavor+model in ONLY when the resolved kind is actually "cloud", so a
  /// not-configured cloud selection keys as the real local kind that runs.
  func rebuildSummaryBuilder() {
    let (config, key) = cloudInputs()
    summaryBuilder = SummaryBuilder(provider: makeDefaultLLMProvider(cloudConfig: config, apiKey: key))
    let configured = (config?.isUsable ?? false) && !(key ?? "").isEmpty
    let kind = resolveProviderKind(preference: ProviderSettings.selection(from: .standard),
                                   foundationAvailable: FoundationModelsProbe.isAvailable(),
                                   cloudConfigured: configured)
    if kind == "cloud", let config {
      providerKind = "cloud:\(config.flavor.rawValue):\(config.model)"
    } else {
      providerKind = kind
    }
  }
```

Then, in `init()` (currently lines ~176–180), add `rebuildSummaryBuilder()` as the last line:

```swift
  init() {
    let prev = UserDefaults.standard.object(forKey: Self.lastOpenedKey) as? Date
    briefingSince = prev ?? Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    UserDefaults.standard.set(Date(), forKey: Self.lastOpenedKey)
    rebuildSummaryBuilder()
  }
```

- [ ] **Step 3: Minimal `SettingsView` — compile with `@AppStorage` + `.cloud` tag**

In `Sources/PensieveApp/SettingsView.swift`, replace the `@State private var provider = Preferences.read(...)` line (line 10) with an `@AppStorage`-backed raw string + a computed binding, and update the picker. Replace lines 10 and 31–39 as follows.

Replace line 10:

```swift
  @AppStorage(PensieveDefaults.llmProviderKey) private var providerRaw = ProviderPreference.auto.rawValue
```

Add this computed binding just below the `foundationAvailable` computed property (after line 14):

```swift
  private var provider: Binding<ProviderPreference> {
    Binding(
      get: { ProviderPreference(rawValue: providerRaw) ?? .auto },
      set: { providerRaw = $0.rawValue }
    )
  }
```

Replace the `Picker(...)` block (lines 31–39) with:

```swift
        Picker("LLM Provider", selection: provider) {
          Text("Automatic").tag(ProviderPreference.auto)
          Text("Foundation Models").tag(ProviderPreference.foundationModels)
          Text("claude -p").tag(ProviderPreference.claudeCLI)
          Text("Cloud (API)").tag(ProviderPreference.cloud)
        }
        .onChange(of: providerRaw) { _, _ in
          model.rebuildSummaryBuilder()
        }
```

(The `if provider == .foundationModels` check on line 40 becomes `if provider.wrappedValue == .foundationModels` — update that one reference.)

- [ ] **Step 4: Remove the dead `PENSIEVE_PREFS` scheme env var**

In `project.yml`, find and delete the `PENSIEVE_PREFS` entry in the scheme's environment/arguments block (search `PENSIEVE_PREFS`). If it's the only custom env var and removing it leaves an empty map, leave the surrounding keys valid YAML (remove just the one line).

- [ ] **Step 5: Build the app + smoke-launch**

```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED.

Then a non-blocking smoke-launch against throwaway stores:

```bash
PENSIEVE_DB=/tmp/smoke-$$.sqlite PENSIEVE_CAPTURE_DB=/tmp/smoke-cap-$$.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
SMOKE_PID=$!; sleep 4; kill $SMOKE_PID
```
Expected: launches and stays up ~4s without crashing (no provider/UserDefaults crash on init).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/PensieveApp.swift Sources/PensieveApp/SettingsView.swift project.yml
git commit -m "feat(app): wire cloud-aware provider factory into AppModel, restore app build"
```

---

## Task 7: Settings cloud subsection (flavor / base URL / key / model + Fetch) + German

**Files:**
- Modify: `Sources/PensieveApp/SettingsView.swift`
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `PensieveDefaults`, `CloudFlavor`, `CloudConfig`, `CloudLLMProvider.listModels`, `KeychainSecretStore`, `AppModel.rebuildSummaryBuilder()`.

- [ ] **Step 1: Add cloud state + subsection to `SettingsView`**

In `Sources/PensieveApp/SettingsView.swift`, add these `@AppStorage`/`@State` members alongside the existing ones (below the `provider` binding):

```swift
  @AppStorage(PensieveDefaults.cloudFlavorKey) private var cloudFlavorRaw = CloudFlavor.anthropic.rawValue
  @AppStorage(PensieveDefaults.cloudBaseURLKey) private var cloudBaseURL = ""
  @AppStorage(PensieveDefaults.cloudModelKey) private var cloudModel = ""
  @State private var apiKeyField = ""
  @State private var models: [String] = []
  @State private var isFetching = false
  @State private var fetchError = false

  private var cloudFlavor: CloudFlavor { CloudFlavor(rawValue: cloudFlavorRaw) ?? .anthropic }
```

Add this cloud subsection INSIDE the `Section("Intelligence")`, right after the foundation-availability `if` block (so it appears only when Cloud is selected):

```swift
        if provider.wrappedValue == .cloud {
          Picker("Provider Type", selection: Binding(
            get: { cloudFlavor },
            set: { newFlavor in
              cloudFlavorRaw = newFlavor.rawValue
              cloudBaseURL = newFlavor.defaultBaseURL          // reset base to the flavor default
              apiKeyField = KeychainSecretStore().read(account: newFlavor.rawValue) ?? ""
              models = []; fetchError = false
              model.rebuildSummaryBuilder()
            }
          )) {
            Text("Anthropic").tag(CloudFlavor.anthropic)
            Text("OpenAI-compatible").tag(CloudFlavor.openAICompatible)
          }

          TextField("Base URL", text: $cloudBaseURL)
            .onChange(of: cloudBaseURL) { _, _ in model.rebuildSummaryBuilder() }

          SecureField("API Key", text: $apiKeyField)
            .onSubmit { commitKey() }

          HStack {
            if models.isEmpty {
              TextField("Model", text: $cloudModel)
                .onChange(of: cloudModel) { _, _ in model.rebuildSummaryBuilder() }
            } else {
              Picker("Model", selection: $cloudModel) {
                ForEach(models, id: \.self) { Text($0).tag($0) }
              }
              .onChange(of: cloudModel) { _, _ in model.rebuildSummaryBuilder() }
            }
            Button(isFetching ? "Fetching…" : "Fetch models") { fetchModels() }
              .disabled(isFetching)
          }

          if fetchError {
            Label("Couldn’t reach the provider. Check the key and base URL.",
                  systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
```

Add these helper methods to the `SettingsView` struct (e.g. after `body`):

```swift
  private func commitKey() {
    KeychainSecretStore().write(apiKeyField, account: cloudFlavor.rawValue)
    model.rebuildSummaryBuilder()
  }

  private func fetchModels() {
    commitKey()   // persist the just-typed key before validating it
    let config = CloudConfig(flavor: cloudFlavor, baseURL: cloudBaseURL, model: cloudModel)
    let key = apiKeyField
    isFetching = true; fetchError = false
    Task {
      defer { isFetching = false }
      do {
        let fetched = try await CloudLLMProvider.listModels(config: config, apiKey: key)
        models = fetched
        if cloudModel.isEmpty, let first = fetched.first {
          cloudModel = first
          model.rebuildSummaryBuilder()
        }
      } catch {
        fetchError = true
      }
    }
  }
```

Load the persisted key into the `SecureField` when the pane appears — add to the `Form`:

```swift
    .onAppear { apiKeyField = KeychainSecretStore().read(account: cloudFlavor.rawValue) ?? "" }
```

- [ ] **Step 2: Add German localizations**

The English keys above are auto-created by SwiftUI at runtime but NOT written into the source `.xcstrings` by `xcodebuild`. Add each new UI string to `Sources/PensieveApp/Localizable.xcstrings` by hand, under `"strings"`, in the existing entry format. Add these entries (merge into the JSON object; keep it valid):

```json
    "Cloud (API)" : {
      "extractionState" : "manual",
      "shouldTranslate" : false
    },
    "Provider Type" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Anbietertyp" } }
      }
    },
    "OpenAI-compatible" : {
      "extractionState" : "manual",
      "shouldTranslate" : false
    },
    "Base URL" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Basis-URL" } }
      }
    },
    "API Key" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "API-Schlüssel" } }
      }
    },
    "Model" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Modell" } }
      }
    },
    "Fetch models" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Modelle abrufen" } }
      }
    },
    "Fetching…" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Wird abgerufen…" } }
      }
    },
    "Couldn’t reach the provider. Check the key and base URL." : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Anbieter nicht erreichbar. Schlüssel und Basis-URL prüfen." } }
      }
    }
```

(Note: `"Anthropic"` needs no entry — proper name, English fallback. `"Provider Type"` label vs the existing `"LLM Provider"` are distinct keys.)

- [ ] **Step 3: Build the app + smoke-launch**

```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED.

```bash
PENSIEVE_DB=/tmp/smoke-$$.sqlite PENSIEVE_CAPTURE_DB=/tmp/smoke-cap-$$.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
SMOKE_PID=$!; sleep 4; kill $SMOKE_PID
```
Expected: launches, stays up ~4s.

- [ ] **Step 4: Verify the German catalog compiles**

```bash
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -i "Basis-URL"
```
Expected: prints the `Base URL → Basis-URL` mapping (confirms the `de` value made it into the built bundle). If nothing prints, a key is mis-typed against the Swift literal — reconcile the exact string (curly quotes, ellipsis `…`, spacing) and rebuild.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/SettingsView.swift Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): add cloud provider settings subsection with model fetch"
```

---

## Post-implementation (human, after merge)

- **Rebuild + reinstall the release CLI** (daemon-adjacent: the provider-selection read changed):
  ```bash
  swift build -c release
  cp .build/release/pensieve ~/.local/bin/pensieve
  ```
  No schema/hook/launchd change; no `install-daemon` re-run needed.
- **Human-verify carries** (see the spec's "Human-verify carries" section) — need the built app + real store + plain `open`: cloud subsection appears; Fetch populates the model picker / a bad key shows the inline error; narration runs via cloud; the key is in Keychain Access and NOT in any plist/JSON; blanking the key falls back to local; the daemon still extracts on-device; cross-process selection honored by a later `pensieve digest`; German in situ (`-AppleLanguages '(de)'`) with vendor names English.

---

## Self-Review

**Spec coverage:**
- Flavor switch (Anthropic/OpenAI-compatible) → Tasks 1–3. ✓
- App-only scope + `allowsCloud`-via-injection (CLI passes no cloud inputs) → Task 5 (`makeDefaultLLMProvider` defaults) + Task 5 CLI edits. ✓
- Fetch-from-API model selection (doubles as key test) → Task 3 `listModels`, Task 7 Fetch button. ✓
- All-UserDefaults storage + `preferences.json` retired → Task 5. ✓
- Cross-process read via `UserDefaults(suiteName:)` (no daemon regression) → `PensieveDefaults.shared()` (Task 5) + CLI edits. ✓
- Per-flavor models path (no double-`/v1`) → Task 1 suffixes + Task 2 `modelsRequestPathsAvoidDoubleV1` test. ✓
- Keychain per-flavor key → Task 4 + Task 7 `account: flavor.rawValue`. ✓
- Transport `HTTPURLResponse` guard-cast → Task 3 `urlSessionTransport`. ✓
- Narration cache key gated on resolved `"cloud"` → Task 6 `rebuildSummaryBuilder`. ✓
- Empty-model inert fallback → `CloudConfig.isUsable` (Task 1) + `makeDefaultLLMProvider` gate (Task 5). ✓
- Trust gate untouched → no extraction/schema/capture change anywhere. ✓
- German chrome only → Task 7 (`Cloud (API)`/`OpenAI-compatible` marked `shouldTranslate:false`). ✓
- `project.yml` `PENSIEVE_PREFS` removal → Task 6. ✓
- One-time selection reset (no migration) → intended; no task (documented in spec). ✓

**Type consistency:** `CloudFlavor`/`CloudConfig`/`CloudHTTP`/`CloudLLMProvider`/`Transport`/`urlSessionTransport`/`listModels`/`resolveProviderKind(…cloudConfigured:)`/`makeDefaultLLMProvider(defaults:cloudConfig:apiKey:)`/`ProviderSettings.selection(from:)`/`PensieveDefaults.*Key` are used identically across tasks. ✓

**Placeholder scan:** every code step shows complete code; no TBD/TODO. ✓
