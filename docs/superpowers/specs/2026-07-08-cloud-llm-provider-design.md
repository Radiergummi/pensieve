# Cloud / API LLM provider — design

**Date:** 2026-07-08
**Status:** approved-pending-review
**Track:** Settings follow-up (Track B) — the motivating long-term case for the shipped provider-preference scaffold.

## Goal

Add a **cloud (HTTP API) `LLMProvider`** as a fourth provider option, so the app can drive its
best-effort **"Last Work Done" narration** with a hosted model (e.g. Claude via the Anthropic API,
or any OpenAI-compatible endpoint) instead of only on-device Foundation Models / `claude -p`.

The API key is stored in the **macOS Keychain**; the non-secret config lives in **UserDefaults**;
model selection is populated by **fetching the provider's model list** (which doubles as key
validation). This builds directly on the shipped `ProviderPreference` / `makeDefaultLLMProvider`
plumbing.

**Non-goals / out of scope:** cloud extraction (the trust-gated loose-end pipeline stays on-device);
streaming; a system-prompt split; per-request cost/telemetry; the daemon or CLI using cloud.

## Decisions (from brainstorming)

1. **Flavor: both, configurable.** One provider with an Anthropic ↔ OpenAI-compatible switch, not
   two structs and not a single hardwired vendor.
2. **Scope: app-only.** The cloud model powers only the app's narration. The launchd sync daemon +
   CLI keep local-first extraction on-device — both because a non-interactive daemon can't reach a
   Keychain item (ad-hoc signed, no paid team → no shared access group) and because on-device
   extraction is the correct privacy/trust-gate posture.
3. **Model selection: fetch from the API.** A **Fetch** button hits `GET /v1/models` and populates a
   picker; a failure surfaces inline. This is also the connection/key test.
4. **Storage: all UserDefaults; `preferences.json` retired.** Non-secret config *and* the provider
   selection move to UserDefaults (the canonical macOS mechanism, matching the app's existing
   `@AppStorage` toggles). The bespoke shared JSON file goes away. The API **key** is in the
   **Keychain**. (Trade-off below.)

### Accepted trade-offs

- **Daemon/CLI lose the persisted provider selection.** With `preferences.json` gone, the CLI's
  argument-free `makeDefaultLLMProvider()` resolves to **Automatic** (Foundation Models if available,
  else `claude -p`). The explicit Foundation-Models-vs-`claude -p` override now applies to the **app
  only**. Automatic is the sensible default and extraction is on-device-preferred, so this is a minor,
  intentional regression to a shipped behavior.
- **One-time selection reset.** The orphaned `preferences.json` is not migrated; the app's persisted
  selection reads as Automatic on first launch after this change. Single-user tool — re-set in
  Settings once. No migration code.
- **Cloud is best-effort, outside the trust gate.** Narration already returns `nil` on provider
  failure (never a facts-dump). A cloud outage/timeout degrades to no-recap, exactly like today.

## Architecture

### Layer map

| Concern | Where | Tested? |
|---|---|---|
| `ProviderPreference` enum (+ `.cloud`) | PensieveKit | pure |
| `CloudFlavor`, `CloudConfig` | PensieveKit | pure |
| Request/response/model-list builders | PensieveKit | pure (unit) |
| `CloudLLMProvider` (`complete`, `listModels`) | PensieveKit | via injected fake transport |
| `resolveProviderKind` / `makeDefaultLLMProvider` | PensieveKit | pure / fake inputs |
| `KeychainSecretStore` (`SecItem` generic-password) | PensieveKit | untested OS boundary |
| Settings UI, `@AppStorage`, Keychain calls, AppModel wiring | PensieveApp | build + smoke-launch |

PensieveKit never touches UserDefaults or the Keychain in its decision path. The **app** reads
UserDefaults + Keychain and **injects** the resolved inputs into the factory. This keeps the kernel
pure and the OS boundaries thin and app-side.

### 1. Types & persistence (PensieveKit)

- Add `case cloud` to `ProviderPreference` (raw value `"cloud"`). Keep the enum; **delete the
  `Preferences` read/write type** and `PensievePaths.preferencesURL()`.
- New value types:
  ```swift
  public enum CloudFlavor: String, Sendable, Codable, CaseIterable {
    case anthropic
    case openAICompatible
    public var defaultBaseURL: String {
      switch self {
      case .anthropic: return "https://api.anthropic.com"
      case .openAICompatible: return "https://api.openai.com/v1"
      }
    }
  }

  public struct CloudConfig: Sendable, Equatable {
    public var flavor: CloudFlavor
    public var baseURL: String   // editable; defaults to flavor.defaultBaseURL
    public var model: String     // e.g. "claude-opus-4-8" / "gpt-4o"
    public var isUsable: Bool { !baseURL.isEmpty && !model.isEmpty }
  }
  ```
- **UserDefaults keys** (app-side, in `AppDefaults`): `llmProvider` (raw), `cloudFlavor` (raw),
  `cloudBaseURL`, `cloudModel`. Persisted via `@AppStorage` in Settings; read by `AppModel` via
  `UserDefaults.standard`.
- **Keychain**: `service = "com.pensieve.cloud-llm"`, `account = flavor.rawValue` so an Anthropic key
  and an OpenAI key coexist and survive a flavor switch.

### 2. `CloudLLMProvider` (PensieveKit)

```swift
public struct CloudLLMProvider: LLMProvider {
  let config: CloudConfig
  let apiKey: String
  let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
  public init(config:apiKey:transport: = URLSession-backed) { ... }

  public func complete(prompt: String) async throws -> String {
    let request = try Self.buildCompletionRequest(config: config, apiKey: apiKey, prompt: prompt)
    let (data, response) = try await transport(request)
    guard (200..<300).contains(response.statusCode) else { throw providerFailed(snippet(data)) }
    return try Self.parseCompletion(flavor: config.flavor, data)
  }

  // Settings uses this to populate the picker AND validate the key.
  public static func listModels(config:apiKey:transport:) async throws -> [String] {
    // GET {baseURL}/v1/models -> parseModelList -> [id]
  }
}
```

Conforms to `LLMProvider` with **only** `complete` — the structured `extractCandidates` /
`classify*` methods inherit the protocol's JSON-decode defaults (cloud is app/narration-only, so
they're never exercised, but the conformance is free and correct).

**Pure helpers (unit-tested, no I/O):**
- `buildCompletionRequest(config:apiKey:prompt:) throws -> URLRequest`
  - Anthropic: `POST {baseURL}/v1/messages`; headers `x-api-key: <key>`,
    `anthropic-version: 2023-06-01`, `content-type: application/json`; body
    `{"model": …, "max_tokens": 1024, "messages": [{"role":"user","content": prompt}]}`.
  - OpenAI-compatible: `POST {baseURL}/chat/completions`; header
    `Authorization: Bearer <key>`; body `{"model": …, "messages": [{"role":"user","content": prompt}]}`.
  - `timeoutInterval = 120`.
- `parseCompletion(flavor:_ data:) throws -> String`
  - Anthropic: `content[0].text`. OpenAI: `choices[0].message.content`. Missing → `providerFailed`.
- `parseModelList(_ data:) throws -> [String]`
  - Both shapes expose `{ "data": [ { "id": … } ] }`; return the `id`s (sorted). Missing → throw.
- `buildModelsRequest(config:apiKey:) -> URLRequest` — `GET {baseURL}/v1/models` (or `/models`
  under an OpenAI base already ending in `/v1`), same auth headers as the flavor.

Injected `transport` defaults to a small `URLSession.shared`-backed closure that maps to
`(Data, HTTPURLResponse)`. Tests pass a fake returning canned `(Data, HTTPURLResponse)` for success,
non-2xx, and malformed-body cases. **No real network in tests.**

### 3. Factory & resolver (PensieveKit `DefaultProvider.swift`)

PensieveKit no longer reads persisted preferences. Remove `resolvedPrefsURL`, the `PENSIEVE_PREFS`
read, and the `prefsURL` params.

```swift
// Pure. cloudConfigured is computed by the caller (app) from config validity + key presence.
public func resolveProviderKind(
  preference: ProviderPreference,
  foundationAvailable: Bool,
  cloudConfigured: Bool
) -> String {
  switch preference {
  case .cloud:            return cloudConfigured ? "cloud" : localKind(foundationAvailable)
  case .auto, .foundationModels:
                          return foundationAvailable ? "foundationModels" : "claudeCLI"
  case .claudeCLI:        return "claudeCLI"
  }
}

public func makeDefaultLLMProvider(
  preference: ProviderPreference = .auto,
  cloudConfig: CloudConfig? = nil,
  apiKey: String? = nil
) -> any LLMProvider {
  let configured = (cloudConfig?.isUsable ?? false) && !(apiKey ?? "").isEmpty
  switch resolveProviderKind(preference: preference,
                             foundationAvailable: foundationModelsIsSelectable(),
                             cloudConfigured: configured) {
  case "cloud":            return CloudLLMProvider(config: cloudConfig!, apiKey: apiKey!)
  case "foundationModels": return FoundationModelsProvider()   // under #if canImport/#available
  default:                 return ClaudeCLIProvider()
  }
}
```

- **CLI/daemon call sites unchanged** — `makeDefaultLLMProvider()` with defaults → `.auto` →
  local-first. (`Ingest.swift`, `Digest.swift`, `Sync.swift` need no edits.)
- **`.cloud` selected but not configured → local-first fallback**, so the app is never stuck on a
  keyless/broken cloud provider.
- Delete the old `defaultProviderKind(prefsURL:)`. The app computes its narration-cache kind by
  calling `resolveProviderKind` directly with its own inputs (see §5).

### 4. `KeychainSecretStore` (PensieveKit)

Thin generic-password wrapper over `Security.SecItem*`:
```swift
public struct KeychainSecretStore {
  public func read(account: String) -> String?
  public func write(_ secret: String, account: String)   // upsert; delete on empty
  public func delete(account: String)
}
```
`service = "com.pensieve.cloud-llm"`. Untested OS boundary (like the app views); errors are
best-effort/swallowed (a failed read ⇒ `nil` ⇒ cloud falls back to local). Only the app calls it.

### 5. Settings UI + AppModel (PensieveApp, thin)

**SettingsView** — the Intelligence section's provider picker gains **Cloud (API)**. Selecting it
reveals a cloud subsection:
- **Flavor** picker (Anthropic / OpenAI-compatible). Changing it resets the Base URL to the flavor
  default and reloads the key field from the Keychain for that flavor's `account`.
- **Base URL** `TextField` (prefilled from `flavor.defaultBaseURL`, editable for gateways).
- **API Key** `SecureField` — on commit, `KeychainSecretStore.write(key, account: flavor.rawValue)`
  (empty ⇒ delete). Never rendered back as plaintext beyond the `SecureField` masking; never written
  to UserDefaults.
- **Model** picker + **Fetch** button: `Task { try await CloudLLMProvider.listModels(config:apiKey:) }`
  → spinner while loading → populates the picker (selection persists to `cloudModel`), or an inline
  `Label(..., systemImage: "exclamationmark.triangle")` error caption on failure (bad key / network /
  parse). If the user hasn't fetched, the picker still shows the persisted `cloudModel` (free choice
  preserved).
- Non-secret fields are `@AppStorage`. Any change calls `model.rebuildSummaryBuilder()`.

**AppModel:**
- `rebuildSummaryBuilder()` reads the selection + cloud config from `UserDefaults.standard` and the
  key from `KeychainSecretStore`, then
  `summaryBuilder = SummaryBuilder(provider: makeDefaultLLMProvider(preference:cloudConfig:apiKey:))`.
- **Narration cache key:** `providerKind` folds flavor+model in for cloud, e.g.
  `"cloud:anthropic:claude-opus-4-8"`, so switching model/flavor busts the existing provider-keyed
  narration cache (⌘R still forces re-narration). Computed via `resolveProviderKind` + a suffix.
- Initial `summaryBuilder` / `providerKind` seed the same way at launch.

**German l10n** for the new chrome: the "Cloud (API)" option, "Flavor"/"Base URL"/"API Key"/"Model"
labels, the "Fetch models" button, and the error caption. Provider/vendor names stay English.

### 6. Trust gate

Untouched. Cloud serves only narration (best-effort, outside the cited trust gate). Extraction stays
on-device via the daemon. No schema, capture, or entitlement change.

## Testing

**PensieveKit (Swift Testing):**
- `resolveProviderKind` — all four preferences × `foundationAvailable` × `cloudConfigured`, incl.
  `.cloud`-but-not-configured → local fallback.
- `buildCompletionRequest` — per flavor: URL, method, headers (`x-api-key`+version / `Bearer`), and
  decoded body fields (model, prompt, `max_tokens` on Anthropic).
- `parseCompletion` — Anthropic `content[0].text`, OpenAI `choices[0].message.content`, and a
  malformed body → throws.
- `parseModelList` — both shapes → `[id]`; empty/malformed → throws.
- `CloudLLMProvider.complete` / `.listModels` — fake transport for 2xx success, non-2xx (error
  snippet), and malformed body.
- Retire/rework `PreferencesTests` and `DefaultProviderTests`: drop the file-based `Preferences.read/
  write` cases (type deleted); keep the pure `resolveProviderKind` cases (now with `cloudConfigured`).

**PensieveApp:** no unit tests — `xcodebuild` build + non-blocking smoke-launch of the inner binary
with throwaway `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`.

**`KeychainSecretStore`:** not unit-tested (real login-keychain access is prompt-prone/flaky) —
verified by hand in the built app.

## Human-verify carries (built app + real store + `open`)

- ⌘, → Intelligence → pick **Cloud (API)** → the cloud subsection appears; enter a real key → **Fetch**
  populates the model picker; a bad key shows the inline error.
- With a valid cloud config, open a node → the "Last Work Done" recap generates via the cloud model
  (compare against Automatic); ⌘R re-narrates; switching model re-narrates (cache busts).
- Cloud config persists across relaunch; the key is in the Keychain (Keychain Access shows the item),
  **not** in `~/Library/Preferences/*.plist` or any JSON.
- Deactivate/blank the key → narration falls back to local (no crash, no facts-dump).
- The launchd daemon (`sync.log`) still extracts on-device (Automatic) regardless of the app's cloud
  setting.
- `preferences.json` is no longer written/read; a stale one is ignored.
- German in situ (`-AppleLanguages '(de)'`) for the new labels; vendor names stay English.

## Deployment

- App: `xcodegen generate && xcodebuild … build`, then `open …/Pensieve.app`.
- **Rebuild + reinstall the release CLI** (`swift build -c release` → copy to `~/.local/bin/pensieve`)
  because the provider-selection read changed (daemon-adjacent). No schema/hook/launchd change.

## Files

**PensieveKit**
- `LLM/Preferences.swift` → keep `ProviderPreference` (+`.cloud`), delete `Preferences` type. (Consider
  renaming to `ProviderPreference.swift`.)
- `LLM/CloudProvider.swift` (new) — `CloudFlavor`, `CloudConfig`, `CloudLLMProvider` + pure builders.
- `LLM/DefaultProvider.swift` — rework `resolveProviderKind` / `makeDefaultLLMProvider`; drop
  `defaultProviderKind`, `resolvedPrefsURL`, `PENSIEVE_PREFS`.
- `Support/KeychainSecretStore.swift` (new).
- `Support/PensievePaths.swift` — remove `preferencesURL()`.

**PensieveApp**
- `SettingsView.swift` — cloud subsection + `@AppStorage` + Keychain calls.
- `AppModel.swift` — factory wiring + narration-cache kind.
- `PensieveApp.swift` — remove `Stores.preferencesURL` + `PENSIEVE_PREFS`.
- `Localizable.xcstrings` — new German keys.

**pensieve (CLI):** no source change (defaults preserve local-first).

**Tests:** rework `PreferencesTests` + `DefaultProviderTests`; add `CloudProviderTests`.
