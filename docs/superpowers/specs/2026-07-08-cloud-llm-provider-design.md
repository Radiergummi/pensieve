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
   **Keychain**. **No daemon regression** — see cross-process note below.

### Cross-process reads (no regression)

The daemon/CLI still honor the persisted provider selection. The app is **not sandboxed** (no
`com.apple.security.app-sandbox` entitlement — and can't get one without a paid team), so its
UserDefaults persist to `~/Library/Preferences/me.mazetti.pensieve.plist`, served by the per-user
`cfprefsd`. The sync LaunchAgent runs in **`gui/501` — the same user** as the app. Therefore any
Pensieve CLI/daemon process reads the app's domain by naming it:

```swift
UserDefaults(suiteName: "me.mazetti.pensieve")   // the app's domain, read from the CLI/daemon
```

This is the standard helper-tool pattern. It only fails under **sandboxing** (prefs move into a
container; cross-process sharing then needs an App Group + Team ID — the blocked gate). Pensieve is
not sandboxed, so it works today. The **key** stays Keychain-only (app-reachable, not daemon), so
cloud remains app-only regardless: the daemon reading the selection just means it honors
Foundation-Models-vs-`claude -p` and falls back to local for a `.cloud` selection it can't key.

### Accepted trade-offs

- **One-time selection reset.** The orphaned `preferences.json` is not migrated; the app's persisted
  selection reads as Automatic on first launch after this change. Single-user tool — re-set in
  Settings once. (A ~3-line one-shot import from the old file could avoid even this; omitted as YAGNI
  unless requested.)
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
| `resolveProviderKind` / `ProviderSettings` reader | PensieveKit | pure / injected `UserDefaults` |
| `makeDefaultLLMProvider` | PensieveKit | reads injected `UserDefaults`; resolver tested separately |
| `PensieveDefaults` (domain + key constants + `shared()`) | PensieveKit | constants |
| `KeychainSecretStore` (`SecItem` generic-password) | PensieveKit | untested OS boundary |
| Settings UI, `@AppStorage`, Keychain calls, AppModel wiring | PensieveApp | build + smoke-launch |

The **pure decision** (`resolveProviderKind`) never touches UserDefaults or the Keychain. The
factory reads the *selection* from an **injected** `UserDefaults` (app → `.standard`; CLI →
`PensieveDefaults.shared()`), and the **app** additionally injects the cloud config + Keychain key.
The Keychain is app-only. This keeps the resolver pure/testable and the OS boundaries thin.

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
- **`PensieveDefaults` (PensieveKit)** owns the shared surface so app + CLI can't drift:
  ```swift
  public enum PensieveDefaults {
    public static let appDomain = "me.mazetti.pensieve"
    public static let llmProviderKey = "llmProvider"
    public static let cloudFlavorKey = "cloudFlavor"
    public static let cloudBaseURLKey = "cloudBaseURL"
    public static let cloudModelKey = "cloudModel"
    // CLI/daemon read the app's domain; falls back to .standard if unavailable.
    public static func shared() -> UserDefaults { UserDefaults(suiteName: appDomain) ?? .standard }
  }
  ```
  Keys are raw strings (`llmProvider`/`cloudFlavor` store enum raw values; `cloudBaseURL`/`cloudModel`
  are strings). The app writes them via `@AppStorage(PensieveDefaults.…Key)` (`.standard` domain);
  the CLI reads via `PensieveDefaults.shared()`. The **API key is never** a default.
- **Keychain**: `service = "com.pensieve.cloud-llm"`, `account = flavor.rawValue` so an Anthropic key
  and an OpenAI key coexist and survive a flavor switch.
- A pure reader `ProviderSettings.selection(from: UserDefaults) -> ProviderPreference` (unknown/absent
  → `.auto`) — testable by injecting a throwaway `UserDefaults(suiteName:)`.

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
    // GET buildModelsRequest(...).url  (per-flavor path, see below) -> parseModelList -> [id]
  }
}
```

Conforms to `LLMProvider` with **only** `complete` — the structured `extractCandidates` /
`classify*` methods inherit the protocol's JSON-decode defaults (cloud is app/narration-only, so
they're never exercised, but the conformance is free and correct).

**Path convention (avoid double-`/v1`).** Each flavor's `baseURL` default already encodes where the
version segment lives — Anthropic `https://api.anthropic.com` (no `/v1`), OpenAI-compatible
`https://api.openai.com/v1` (with `/v1`). A single per-flavor **suffix** is appended to the raw
`baseURL`; the builders **never** synthesize or strip a `/v1`, so a user-edited gateway base is passed
through verbatim:

| Flavor | completion suffix | models suffix |
|---|---|---|
| `.anthropic` | `/v1/messages` | `/v1/models` |
| `.openAICompatible` | `/chat/completions` | `/models` |

**Pure helpers (unit-tested, no I/O), all headers set per flavor (see auth below):**
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
- `buildModelsRequest(config:apiKey:) -> URLRequest` — `GET {baseURL}{models-suffix}` per the table
  above, carrying the **same auth headers as the flavor's completion request** (Anthropic also sends
  `x-api-key` **and** `anthropic-version`; OpenAI sends `Authorization: Bearer`).

Injected `transport` defaults to a small `URLSession.shared.data(for:)`-backed closure that
**guard-casts** the returned `URLResponse` to `HTTPURLResponse` (throwing `providerFailed` if not —
never a force-cast). Tests pass a fake returning canned `(Data, HTTPURLResponse)` for success,
non-2xx (asserting the error snippet), and malformed-body cases. **No real network in tests.**

### 3. Factory & resolver (PensieveKit `DefaultProvider.swift`)

The file-reading path (`resolvedPrefsURL`, the `PENSIEVE_PREFS` read, `Preferences.read`,
`prefsURL` params, `defaultProviderKind(prefsURL:)`) is removed. The factory now reads the
*selection* from an injected `UserDefaults` and keeps the decision itself pure.

```swift
// Pure. cloudConfigured is computed by the caller from config validity + key presence.
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
  defaults: UserDefaults = .standard,       // app → .standard; CLI → PensieveDefaults.shared()
  cloudConfig: CloudConfig? = nil,          // app-only (nil ⇒ never cloud)
  apiKey: String? = nil                     // app-only (Keychain)
) -> any LLMProvider {
  let preference = ProviderSettings.selection(from: defaults)
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

- **CLI/daemon call sites change to read the app domain**: `makeDefaultLLMProvider(defaults:
  PensieveDefaults.shared())` in `Ingest.swift`, `Digest.swift`, `Sync.swift`. With no cloud inputs,
  a `.cloud` selection falls back to local; every other selection is honored (**no regression**).
- **`.cloud` selected but not configured → local-first fallback**, so the app is never stuck on a
  keyless/broken cloud provider.
- The app computes its narration-cache kind by calling `resolveProviderKind` directly with its own
  inputs (see §5) — no separate `defaultProviderKind`.

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
  preserved); an empty `cloudModel` ⇒ `CloudConfig.isUsable == false` ⇒ not configured ⇒ narration
  falls back to local (no error state — the cloud option is simply inert until a model is set).
- Non-secret fields are `@AppStorage`. Any change calls `model.rebuildSummaryBuilder()`.

**AppModel:**
- `rebuildSummaryBuilder()` reads the cloud config from `UserDefaults.standard` and the key from
  `KeychainSecretStore`, then
  `summaryBuilder = SummaryBuilder(provider: makeDefaultLLMProvider(cloudConfig:apiKey:))` (defaults
  `.standard` for the selection — the app's own domain).
- **Narration cache key:** `providerKind` folds flavor+model in **only when the resolved kind is
  `"cloud"`**, e.g. `"cloud:anthropic:claude-opus-4-8"`; a `.cloud`-but-not-configured fallback keys
  as the plain local kind (`"claudeCLI"`/`"foundationModels"`), matching what actually runs. Switching
  model/flavor busts the existing provider-keyed `NarrationCacheKey`. Note: this busts the *cache* — an
  already-open recap in the main window doesn't auto-refresh on a Settings change (Settings is a
  separate window; the `.task(id:)` doesn't re-fire); **⌘R re-narrates under the new model**.
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
- `ProviderSettings.selection(from:)` — inject a throwaway `UserDefaults(suiteName:)`, write each raw
  value, assert the mapped preference (and unknown/absent → `.auto`).
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
  (compare against Automatic); ⌘R re-narrates; after changing the model in Settings, **⌘R** on the node
  re-narrates under the new model (the cache is busted; the open recap doesn't auto-refresh).
- Cloud config persists across relaunch; the key is in the Keychain (Keychain Access shows the item),
  **not** in `~/Library/Preferences/*.plist` or any JSON. (Ad-hoc signing means macOS may re-prompt to
  authorize the keychain item after each rebuild — expected, not a failure.)
- Deactivate/blank the key → narration falls back to local (no crash, no facts-dump).
- **Cross-process selection is honored:** set the app's provider to Foundation Models (or `claude -p`)
  → a subsequent `pensieve digest`/`sync` uses that same provider (reads `me.mazetti.pensieve` via
  `UserDefaults(suiteName:)`); set it to Cloud → the CLI falls back to local (no Keychain reach), the
  app uses cloud.
- The launchd daemon (`sync.log`) always extracts on-device for a `.cloud` selection (falls back).
- `preferences.json` is no longer written/read; a stale one is ignored.
- German in situ (`-AppleLanguages '(de)'`) for the new labels; vendor names stay English.

## Deployment

- App: `xcodegen generate && xcodebuild … build`, then `open …/Pensieve.app`.
- **Rebuild + reinstall the release CLI** (`swift build -c release` → copy to `~/.local/bin/pensieve`)
  because the provider-selection read changed (daemon-adjacent). No schema/hook/launchd change.

## Files

**PensieveKit**
- `LLM/Preferences.swift` → keep `ProviderPreference` (+`.cloud`), delete `Preferences` type; add
  `ProviderSettings.selection(from:)`. (Consider renaming to `ProviderPreference.swift`.)
- `LLM/CloudProvider.swift` (new) — `CloudFlavor`, `CloudConfig`, `CloudLLMProvider` + pure builders.
- `LLM/DefaultProvider.swift` — rework `resolveProviderKind` / `makeDefaultLLMProvider(defaults:…)`;
  drop `defaultProviderKind`, `resolvedPrefsURL`, `PENSIEVE_PREFS`.
- `Support/PensieveDefaults.swift` (new) — domain + key constants + `shared()`.
- `Support/KeychainSecretStore.swift` (new).
- `Support/PensievePaths.swift` — remove `preferencesURL()`.

**PensieveApp**
- `SettingsView.swift` — cloud subsection + `@AppStorage(PensieveDefaults.…Key)` + Keychain calls.
- `AppModel.swift` — factory wiring (`makeDefaultLLMProvider(cloudConfig:apiKey:)`) + narration-cache kind.
- `PensieveApp.swift` — remove `Stores.preferencesURL` + `PENSIEVE_PREFS`.
- `Localizable.xcstrings` — new German keys.

**pensieve (CLI):** `Ingest.swift`, `Digest.swift`, `Sync.swift` change their `makeDefaultLLMProvider()`
call to `makeDefaultLLMProvider(defaults: PensieveDefaults.shared())` so the CLI/daemon read the app's
domain.

**`project.yml`:** remove the now-dead `PENSIEVE_PREFS` scheme env var.

**Tests hygiene:** `ProviderSettings.selection(from:)` tests use a unique random
`UserDefaults(suiteName:)` per test and `removePersistentDomain(forName:)` in cleanup so throwaway
domains don't accumulate as `~/Library/Preferences/<suite>.plist`.

**Tests:** rework `PreferencesTests` + `DefaultProviderTests`; add `CloudProviderTests`.
