# Provider Settings polish — design

**Date:** 2026-07-09
**Status:** approved (design)
**Scope:** app-target (`Sources/PensieveApp/SettingsView.swift`, `AppModel.swift`) + PensieveKit LLM/support helpers. **Out of scope:** the trust gate, extraction, streaming, per-request cost/telemetry, daemon/CLI cloud use.

## Motivation

The Settings provider panel (shipped in the cloud/API provider track) works but feels unfinished, and a review surfaced a UI↔model mismatch and a few robustness gaps. Separately we want the panel to (a) offer common cloud vendors with pre-filled base URLs, (b) give the provider options friendlier, localizable labels, and (c) explain the quality/privacy tradeoff — on-device vs. cloud inference differs a lot in quality, and the user should understand what they're choosing.

Cloud only ever serves the app's **best-effort "Last Work Done" narration** (outside the strict cited trust gate). Extraction stays on-device. None of this changes that.

## Non-goals

- No change to `ProviderPreference` cases or any persisted UserDefaults key names → the CLI/daemon cross-process read and the keyless-daemon fallback are untouched.
- No flattening of the provider IA into a single list (considered; rejected as a larger refactor for no correctness gain).
- No new "selected preset" persisted key — presets are derived from the existing `cloudFlavor` + `cloudBaseURL`.

## A. Information architecture

Unchanged at the top level. The provider picker keeps four options (`auto` / `foundationModels` / `claudeCLI` / `cloud`). Vendor presets live **inside** the Cloud section as a "Vendor" picker. The flavor + free base-URL fields only appear when the vendor is **Custom**.

```
Intelligence
  [x] Show "Last Work Done" narration
  Provider:  ( Automatic ▾ )
  ℹ <per-selection help caption>

  — when Provider = Cloud (API) —
  Vendor:   ( OpenAI ▾ )              // presets + Custom
  — when Vendor = Custom —
    Provider Type: ( OpenAI-compatible ▾ )   // = CloudFlavor
    Base URL:      [ … ]
  — always, for Cloud —
  API Key:  [ •••••••• ]
  Model:    ( … ▾ ) [ Fetch models ]
  ℹ <fetch status / error>
```

## B. Vendor presets (PensieveKit — pure & tested)

New file `Sources/PensieveKit/LLM/CloudPresets.swift`:

```swift
public struct CloudPreset: Sendable, Equatable, Identifiable {
  public let id: String          // stable slug, e.g. "openai"
  public let displayName: String // proper name, NOT localized
  public let flavor: CloudFlavor
  public let baseURL: String
}

public enum CloudPresets {
  public static let all: [CloudPreset]   // the table below, in this order
  /// The preset whose (flavor, baseURL) matches, else nil ⇒ "Custom".
  public static func match(flavor: CloudFlavor, baseURL: String) -> CloudPreset?
}
```

Shipping presets:

| id | displayName | flavor | baseURL |
|---|---|---|---|
| `openai` | OpenAI | openAICompatible | `https://api.openai.com/v1` |
| `anthropic` | Anthropic | anthropic | `https://api.anthropic.com` |
| `gemini` | Google Gemini | openAICompatible | `https://generativelanguage.googleapis.com/v1beta/openai` |
| `groq` | Groq | openAICompatible | `https://api.groq.com/openai/v1` |
| `openrouter` | OpenRouter | openAICompatible | `https://openrouter.ai/api/v1` |
| `mistral` | Mistral | openAICompatible | `https://api.mistral.ai/v1` |
| `ollama` | Ollama (local) | openAICompatible | `http://localhost:11434/v1` |

Plus a synthetic **Custom** entry in the picker (not in `all`; represented by `nil` selection).

**Derivation, not persistence.** Presets are pure UI sugar over the existing keys:
- The Vendor picker's current value = `CloudPresets.match(flavor: cloudFlavor, baseURL: cloudBaseURL)` (or Custom when nil).
- Selecting a preset writes `cloudFlavor = preset.flavor` and `cloudBaseURL = preset.baseURL`.
- Selecting **Custom** leaves the current flavor/URL and reveals the flavor picker + free base-URL field.
- Editing the base URL to an unknown value naturally re-derives to Custom on the next read.

Vendor `displayName`s are proper names → never localized (consistent with existing "Anthropic" / "OpenAI-compatible" treatment for names).

## C. Keyless localhost (Ollama and local OpenAI servers)

Local servers need no API key, but today `configured` requires a non-empty key — which is also the safety that makes the keyless CLI/daemon fall back to local. Relax it **only for local endpoints**.

Add to `CloudConfig`:

```swift
/// True when the base URL host is a loopback address. Lets a keyless local server
/// (e.g. Ollama) count as configured without weakening the remote-vendor key requirement.
public var isLocalEndpoint: Bool  // host ∈ { localhost, 127.0.0.1, ::1 }
```

Change the `configured` computation in `resolvedProviderKind` (the single place that computes it):

```swift
let configured = (cloudConfig?.isUsable ?? false)
  && (!(apiKey ?? "").isEmpty || (cloudConfig?.isLocalEndpoint ?? false))
```

The innermost pure `resolveProviderKind(preference:foundationAvailable:cloudConfigured:)` is unchanged — it already takes `cloudConfigured` as a computed Bool.

**Latent-crash fix (required by this change):** `makeDefaultLLMProvider` currently builds `CloudLLMProvider(config: cloudConfig!, apiKey: apiKey!)`. With keyless localhost the key can be `nil`, so `apiKey!` would trap. Change to `apiKey ?? ""`. (Was previously safe only because cloud was never resolved with an empty/nil key.)

Consequences:
- Remote vendors with no key → still fall back to local (unchanged).
- The keyless daemon reading a remote `.cloud` selection → still falls back to local (unchanged).
- The keyless daemon reading a **localhost** `.cloud` selection → would attempt the local server; acceptable (best-effort narration; local server is reachable or narration is nil). Documented, not a regression for remote.

## D. Localization: friendly labels + per-selection explainer (app catalog)

`ProviderPreference` stays raw-value-only. The app owns display in `SettingsView` via the String Catalog. Each case maps to a **localizable friendly label** and a **localizable help caption**:

| Case | Label (localizable) | Help caption (localizable) |
|---|---|---|
| `auto` | Automatic | Picks the best on-device option — Foundation Models when available, otherwise the Claude CLI. |
| `foundationModels` | On-device (Foundation Models) | Runs entirely on-device. Private and free, but noticeably lower quality than a frontier cloud model. |
| `claudeCLI` | Claude CLI (subscription) | Uses your Claude subscription via the `claude` command. Good quality, stays on your account. |
| `cloud` | Cloud (API) | Highest quality. Sends recent activity excerpts to the chosen vendor's API. |

Also:
- The `CloudFlavor` "OpenAI-compatible" label becomes localizable ("Anthropic" stays — proper name).
- The existing Foundation-Models-unavailable note stays (shown when `.foundationModels` is chosen on a Mac without it).
- Fetch status strings (below) are localizable.

All new keys get a German value (impersonal/infinitive), reconciled **by hand** in `Localizable.xcstrings` (xcodebuild does not auto-populate the source catalog). A mis-keyed `de` value silently falls back to English, so verify with a forced-locale launch.

## E. Polish fixes (from the review)

1. **Base-URL prefill / mismatch.** On entering Cloud or selecting a preset, if `cloudBaseURL` is empty, set it to the flavor default. `AppModel.cloudInputs()` changes its base-URL fallback from "nil ⇒ default" to "nil-or-empty ⇒ default", so the UI and the model agree on whether cloud is configured.
2. **Rebuild on commit, not per keystroke.** The free-text Base URL and Model fields rebuild the summary builder on **focus-loss / `.onSubmit`** (via `@FocusState`), not on every character (each rebuild currently does a Keychain read). The Model **Picker** keeps its discrete `.onChange` rebuild.
3. **Robust API-key commit.** Commit the key on **focus-loss** (`@FocusState`) as the primary trigger, keeping `.onSubmit` and `.onDisappear` as backstops (the `Settings` scene's `.onDisappear` is unreliable on window close). Keep the `apiKeyField != loadedKey` guard to skip redundant Keychain writes.
4. **Model picker can't strand a value.** When rendering the fetched-models Picker, union the current `cloudModel` into the options if it isn't already present, so a custom/stale model still shows as selected rather than blank.
5. **Fetch affordances.** Disable "Fetch models" until the base URL is non-empty and (a key is present **or** the endpoint is local). Clear `fetchError` on any base-URL / key / flavor / vendor edit. Show success feedback ("N models available") after a successful fetch.

## F. Testing

New PensieveKit tests (app target stays untested per convention — verify via `xcodebuild` build + non-blocking smoke-launch of the inner binary):

- `CloudPresets.match` returns the right preset for each shipping (flavor, baseURL); returns `nil` (Custom) for an unknown base URL and for a matching flavor but edited URL.
- `CloudConfig.isLocalEndpoint` — true for `http://localhost:11434/v1`, `http://127.0.0.1:...`, `http://[::1]:...`; false for remote hosts and empty.
- `resolvedProviderKind` — keyless **localhost** cloud with base URL + model ⇒ `"cloud"`; keyless **remote** cloud ⇒ local fallback; keyed remote cloud ⇒ `"cloud"`.

## Files touched

- **PensieveKit (new):** `LLM/CloudPresets.swift`.
- **PensieveKit (edit):** `LLM/CloudProvider.swift` (`CloudConfig.isLocalEndpoint`), `LLM/DefaultProvider.swift` (`configured` localhost allowance + `apiKey ?? ""` fix).
- **App (edit):** `SettingsView.swift` (vendor picker, prefill, focus-based commits, model union, fetch affordances, localized labels + captions), `AppModel.swift` (`cloudInputs()` empty-fallback), `Localizable.xcstrings` (new keys + German).
- **Tests (new):** `Tests/PensieveKitTests/` — presets + localhost + resolver cases.

## Risks / rollback

- Trust gate untouched; cloud is narration-only. Worst case a bad narration ⇒ nil (best-effort).
- No persisted-key or enum changes ⇒ no migration, no CLI/daemon regression for remote selections.
- The one behavioral change is the localhost keyless allowance (Section C), scoped to loopback hosts.
