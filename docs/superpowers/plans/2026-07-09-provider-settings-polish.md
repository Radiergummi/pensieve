# Provider Settings Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add vendor presets, keyless-localhost support, friendly localizable provider labels + a per-selection explainer, and the review's polish fixes to the app's LLM-provider Settings panel.

**Architecture:** New logic lands in tested PensieveKit helpers (`CloudConfig.isLocalEndpoint`, `CloudPresets`); the resolver gains a localhost allowance; the app-target `SettingsView` is rewritten to consume them (thin, untested per convention). No `ProviderPreference` case or persisted UserDefaults key changes — the CLI/daemon cross-process read is untouched. The Keychain account moves from flavor-keyed to a derived per-vendor identity.

**Tech Stack:** Swift 6, SwiftUI (`Form`/`@AppStorage`/`@FocusState`), Swift Testing (`@Test`), XcodeGen + xcodebuild for the app, String Catalog (`Localizable.xcstrings`) for l10n.

## Global Constraints

- **No Python, ever. Swift only.**
- **SQLiteData predicates use `.eq(x)`, not `== x`** (not relevant here, but the house rule).
- **The trust gate is untouched** — cloud serves best-effort narration only; extraction stays on-device.
- **No new persisted UserDefaults key and no `ProviderPreference` case change** — presets and the Keychain account are *derived* from the existing `cloudFlavor` + `cloudBaseURL` keys.
- **Vendor proper names are never localized** (OpenAI, Anthropic, Groq, OpenRouter, Mistral, Google Gemini, Ollama). Descriptive chrome (labels, captions, "Vendor", "Custom", "OpenAI-compatible") **is** localized (English base + German `de`, impersonal/infinitive).
- **`xcodebuild` does not auto-populate `Localizable.xcstrings`** — new keys are authored by hand mirroring existing entries; a mis-keyed `de` silently falls back to English.
- **Kit tests:** run with `./scripts/test.sh` (or `swift test`). **App has no unit tests** — verify with an `xcodebuild` build + a non-blocking smoke-launch of the inner binary.
- **Build the app:** `xcodegen generate` then `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`; product at `./.build-xcode/Build/Products/Debug/Pensieve.app`.

---

### Task 1: Keyless-localhost allowance + crash fix (PensieveKit)

**Files:**
- Modify: `Sources/PensieveKit/LLM/CloudProvider.swift` (add `CloudConfig.isLocalEndpoint`)
- Modify: `Sources/PensieveKit/LLM/DefaultProvider.swift` (`configured` localhost term + `apiKey ?? ""`)
- Test: `Tests/PensieveKitTests/DefaultProviderTests.swift` (append cases), `Tests/PensieveKitTests/CloudProviderTests.swift` (append `isLocalEndpoint` cases)

**Interfaces:**
- Produces: `CloudConfig.isLocalEndpoint: Bool`; unchanged signatures for `resolveProviderKind`, `resolvedProviderKind`, `makeDefaultLLMProvider`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/CloudProviderTests.swift`:

```swift
@Test func isLocalEndpointDetectsLoopback() {
  #expect(CloudConfig(flavor: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "m").isLocalEndpoint)
  #expect(CloudConfig(flavor: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1", model: "m").isLocalEndpoint)
  #expect(CloudConfig(flavor: .openAICompatible, baseURL: "http://[::1]:11434/v1", model: "m").isLocalEndpoint)
  #expect(!CloudConfig(flavor: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "m").isLocalEndpoint)
  #expect(!CloudConfig(flavor: .openAICompatible, baseURL: "", model: "m").isLocalEndpoint)
}
```

Append to `Tests/PensieveKitTests/DefaultProviderTests.swift`:

```swift
@Test func keylessLocalhostCloudResolvesToCloud() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  d.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  let cfg = CloudConfig(flavor: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "llama3")
  // Empty key + local endpoint ⇒ configured ⇒ "cloud".
  #expect(resolvedProviderKind(defaults: d, cloudConfig: cfg, apiKey: "") == "cloud")
  // And the factory must not crash on the nil/empty key.
  _ = makeDefaultLLMProvider(defaults: d, cloudConfig: cfg, apiKey: nil)
}

@Test func keylessRemoteCloudFallsBackToLocal() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  d.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  let cfg = CloudConfig(flavor: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-4o")
  let kind = resolvedProviderKind(defaults: d, cloudConfig: cfg, apiKey: "")
  #expect(kind == "foundationModels" || kind == "claudeCLI")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter isLocalEndpointDetectsLoopback` then `./scripts/test.sh --filter keylessLocalhostCloudResolvesToCloud`
Expected: FAIL — `isLocalEndpoint` doesn't exist (compile error) / keyless localhost resolves to a local kind, not `"cloud"`.

- [ ] **Step 3: Add `isLocalEndpoint` to `CloudConfig`**

In `Sources/PensieveKit/LLM/CloudProvider.swift`, inside `struct CloudConfig`, after `isUsable`:

```swift
  /// True when the base URL host is a loopback address. Lets a keyless local server (e.g. Ollama)
  /// count as configured without weakening the remote-vendor key requirement.
  public var isLocalEndpoint: Bool {
    guard let host = URLComponents(string: baseURL)?.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
  }
```

- [ ] **Step 4: Add the localhost term + fix the force-unwrap in `DefaultProvider.swift`**

In `resolvedProviderKind`, change the `configured` line:

```swift
  let configured = (cloudConfig?.isUsable ?? false)
    && (!(apiKey ?? "").isEmpty || (cloudConfig?.isLocalEndpoint ?? false))
```

In `makeDefaultLLMProvider`, change the `"cloud"` case:

```swift
  case "cloud":
    return CloudLLMProvider(config: cloudConfig!, apiKey: apiKey ?? "")
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter CloudProvider` then `./scripts/test.sh --filter DefaultProvider`
Expected: PASS (all cases, including the pre-existing ones).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/LLM/CloudProvider.swift Sources/PensieveKit/LLM/DefaultProvider.swift Tests/PensieveKitTests/CloudProviderTests.swift Tests/PensieveKitTests/DefaultProviderTests.swift
git commit -F - <<'EOF'
feat(llm): allow keyless localhost cloud provider (Ollama), fix apiKey unwrap

Add CloudConfig.isLocalEndpoint; count a local endpoint as configured with
an empty key so Ollama works keyless, while remote vendors still require a
key (daemon fallback preserved). Fix a latent force-unwrap in the factory.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GYk35bcbwrnKorHstUcYUd
EOF
```

---

### Task 2: Cloud vendor presets (PensieveKit)

**Files:**
- Create: `Sources/PensieveKit/LLM/CloudPresets.swift`
- Test: `Tests/PensieveKitTests/CloudPresetsTests.swift`

**Interfaces:**
- Consumes: `CloudFlavor` (from `CloudProvider.swift`).
- Produces:
  - `struct CloudPreset: Sendable, Equatable, Identifiable { let id: String; let displayName: String; let flavor: CloudFlavor; let baseURL: String }`
  - `enum CloudPresets { static let all: [CloudPreset]; static func match(flavor:baseURL:) -> CloudPreset?; static func keychainAccount(flavor:baseURL:) -> String }`

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/CloudPresetsTests.swift`:

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func presetsMatchByFlavorAndBaseURL() {
  let openai = CloudPresets.all.first { $0.id == "openai" }!
  #expect(CloudPresets.match(flavor: openai.flavor, baseURL: openai.baseURL)?.id == "openai")

  let anthropic = CloudPresets.all.first { $0.id == "anthropic" }!
  #expect(CloudPresets.match(flavor: anthropic.flavor, baseURL: anthropic.baseURL)?.id == "anthropic")
}

@Test func editedBaseURLReadsAsCustom() {
  // Matching flavor but a base URL that isn't any preset ⇒ nil (Custom).
  #expect(CloudPresets.match(flavor: .openAICompatible, baseURL: "https://gateway.example/v1") == nil)
  #expect(CloudPresets.match(flavor: .anthropic, baseURL: "https://api.anthropic.com/edited") == nil)
}

@Test func distinctVendorsOfSameFlavorHaveDistinctIDs() {
  let openAICompatIDs = CloudPresets.all.filter { $0.flavor == .openAICompatible }.map(\.id)
  #expect(Set(openAICompatIDs).count == openAICompatIDs.count)   // no dupes
  #expect(openAICompatIDs.contains("openai") && openAICompatIDs.contains("groq"))
}

@Test func keychainAccountIsPerVendorElseCustom() {
  #expect(CloudPresets.keychainAccount(flavor: .openAICompatible, baseURL: "https://api.openai.com/v1") == "openai")
  #expect(CloudPresets.keychainAccount(flavor: .openAICompatible, baseURL: "https://api.groq.com/openai/v1") == "groq")
  #expect(CloudPresets.keychainAccount(flavor: .anthropic, baseURL: "https://api.anthropic.com") == "anthropic")
  // Unknown URL ⇒ a per-flavor custom slot, distinct across flavors.
  #expect(CloudPresets.keychainAccount(flavor: .openAICompatible, baseURL: "https://x/v1") == "custom.openAICompatible")
  #expect(CloudPresets.keychainAccount(flavor: .anthropic, baseURL: "https://x") == "custom.anthropic")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test.sh --filter CloudPresets`
Expected: FAIL — `CloudPresets` / `CloudPreset` not defined (compile error).

- [ ] **Step 3: Implement `CloudPresets.swift`**

Create `Sources/PensieveKit/LLM/CloudPresets.swift`:

```swift
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test.sh --filter CloudPresets`
Expected: PASS (all four tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/LLM/CloudPresets.swift Tests/PensieveKitTests/CloudPresetsTests.swift
git commit -F - <<'EOF'
feat(llm): add cloud vendor presets with per-vendor keychain account

CloudPresets.all (OpenAI, Anthropic, Gemini, Groq, OpenRouter, Mistral,
Ollama), match(flavor:baseURL:), and keychainAccount(flavor:baseURL:) so
vendors sharing the openAICompatible flavor no longer collide on one key.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GYk35bcbwrnKorHstUcYUd
EOF
```

---

### Task 3: AppModel — per-vendor key read + base-URL empty fallback + cache key (PensieveKit-consuming app code)

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift` (`cloudInputs()` and `rebuildSummaryBuilder()`)

**Interfaces:**
- Consumes: `CloudPresets.keychainAccount(flavor:baseURL:)` (Task 2), `CloudFlavor.defaultBaseURL`.
- Produces: no new public surface; `cloudInputs()` now returns a config whose `baseURL` is the flavor default when the stored value is empty, and reads the key from the per-vendor account.

This task has no unit test (app target). Verify by building.

- [ ] **Step 1: Update `cloudInputs()`**

In `Sources/PensieveApp/AppModel.swift`, replace the body of `cloudInputs()` with:

```swift
  private func cloudInputs() -> (CloudConfig?, String?) {
    let d = UserDefaults.standard
    guard let raw = d.string(forKey: PensieveDefaults.cloudFlavorKey),
          let flavor = CloudFlavor(rawValue: raw) else { return (nil, nil) }
    let stored = d.string(forKey: PensieveDefaults.cloudBaseURLKey) ?? ""
    let baseURL = stored.isEmpty ? flavor.defaultBaseURL : stored   // empty ⇒ default, matching the UI
    let model = d.string(forKey: PensieveDefaults.cloudModelKey) ?? ""
    let config = CloudConfig(flavor: flavor, baseURL: baseURL, model: model)
    let key = KeychainSecretStore().read(account: CloudPresets.keychainAccount(flavor: flavor, baseURL: baseURL))
    return (config, key)
  }
```

- [ ] **Step 2: Update the cache-key composition in `rebuildSummaryBuilder()`**

Replace the `if kind == "cloud"` block with:

```swift
    if kind == "cloud", let config {
      let account = CloudPresets.keychainAccount(flavor: config.flavor, baseURL: config.baseURL)
      providerKind = "cloud:\(account):\(config.model)"
    } else {
      providerKind = kind
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift
git commit -F - <<'EOF'
refactor(app): read cloud key per-vendor, default empty base URL, key cache by vendor

cloudInputs() falls back to the flavor default when base URL is empty (so
the model and the UI agree on configured), reads the key from the derived
per-vendor account, and folds the account into the narration cache key.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GYk35bcbwrnKorHstUcYUd
EOF
```

---

### Task 4: SettingsView rewrite — presets, prefill, focus commits, model union, fetch affordances, localized labels + explainer

**Files:**
- Modify (rewrite): `Sources/PensieveApp/SettingsView.swift`

**Interfaces:**
- Consumes: `CloudPresets` (Task 2), `CloudConfig.isLocalEndpoint` (Task 1), `AppModel.rebuildSummaryBuilder()`, `CloudPresets.keychainAccount`.

No unit test (app target). Verify by build + smoke-launch. Localization keys are added in Task 5; this task uses `LocalizedStringKey` literals so those keys get referenced.

- [ ] **Step 1: Rewrite `SettingsView.swift`**

Replace the entire file with:

```swift
import SwiftUI
import AppKit
import PensieveKit

/// The app's Settings pane (⌘,). Reads/writes provider preferences via @AppStorage — no @Published
/// mirror on AppModel; the only AppModel touch is rebuilding its summary builder on a change.
struct SettingsView: View {
  @ObservedObject var model: AppModel
  @AppStorage(PensieveDefaults.llmProviderKey) private var providerRaw = ProviderPreference.auto.rawValue
  @AppStorage(AppDefaults.hideDockIconKey) private var hideDockIcon = false
  @AppStorage(AppDefaults.narrationEnabledKey) private var narrationEnabled = true

  @AppStorage(PensieveDefaults.cloudFlavorKey) private var cloudFlavorRaw = CloudFlavor.anthropic.rawValue
  @AppStorage(PensieveDefaults.cloudBaseURLKey) private var cloudBaseURL = ""
  @AppStorage(PensieveDefaults.cloudModelKey) private var cloudModel = ""

  @State private var apiKeyField = ""
  /// Mirrors the last-persisted Keychain value, so an edited-but-unsubmitted key is distinguishable
  /// from an unchanged one (skips a redundant Keychain write / re-auth prompt).
  @State private var loadedKey = ""
  @State private var models: [String] = []
  @State private var isFetching = false
  @State private var fetchError = false
  @State private var didFetch = false

  @FocusState private var keyFocused: Bool
  @FocusState private var baseURLFocused: Bool
  @FocusState private var modelFocused: Bool

  private var foundationAvailable: Bool { FoundationModelsProbe.isAvailable() }
  private var cloudFlavor: CloudFlavor { CloudFlavor(rawValue: cloudFlavorRaw) ?? .anthropic }
  private var keychainAccount: String { CloudPresets.keychainAccount(flavor: cloudFlavor, baseURL: cloudBaseURL) }

  private var provider: Binding<ProviderPreference> {
    Binding(get: { ProviderPreference(rawValue: providerRaw) ?? .auto },
            set: { providerRaw = $0.rawValue })
  }

  private func label(for p: ProviderPreference) -> LocalizedStringKey {
    switch p {
    case .auto: return "Automatic"
    case .foundationModels: return "On-device (Foundation Models)"
    case .claudeCLI: return "Claude CLI (subscription)"
    case .cloud: return "Cloud (API)"
    }
  }

  private func help(for p: ProviderPreference) -> LocalizedStringKey {
    switch p {
    case .auto: return "Picks the best on-device option — Foundation Models when available, otherwise the Claude CLI."
    case .foundationModels: return "Runs entirely on-device. Private and free, but noticeably lower quality than a frontier cloud model."
    case .claudeCLI: return "Uses your Claude subscription via the claude command. Good quality, stays on your account."
    case .cloud: return "Highest quality. Sends recent activity excerpts to the chosen vendor's API."
    }
  }

  var body: some View {
    Form {
      Section("General") {
        Toggle("Hide Dock icon (menu bar only)", isOn: $hideDockIcon)
          .onChange(of: hideDockIcon) { _, hidden in
            NSApp.setActivationPolicy(hidden ? .accessory : .regular)
            if !hidden { NSApp.activate(ignoringOtherApps: true) }
          }
      }
      Section("Intelligence") {
        Toggle("Show “Last Work Done” narration", isOn: $narrationEnabled)

        Picker("LLM Provider", selection: provider) {
          ForEach([ProviderPreference.auto, .foundationModels, .claudeCLI, .cloud], id: \.self) { p in
            Text(label(for: p)).tag(p)
          }
        }
        .onChange(of: providerRaw) { _, _ in
          if provider.wrappedValue == .cloud, cloudBaseURL.isEmpty { cloudBaseURL = cloudFlavor.defaultBaseURL }
          model.rebuildSummaryBuilder()
        }

        Label(help(for: provider.wrappedValue), systemImage: "info.circle")
          .font(.caption).foregroundStyle(.secondary)

        if provider.wrappedValue == .foundationModels && !foundationAvailable {
          Label("Foundation Models isn’t available on this Mac — using claude -p instead.",
                systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.secondary)
        }

        if provider.wrappedValue == .cloud { cloudSection }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .onAppear {
      apiKeyField = KeychainSecretStore().read(account: keychainAccount) ?? ""
      loadedKey = apiKeyField
    }
  }

  @ViewBuilder private var cloudSection: some View {
    Picker("Vendor", selection: vendorSelection) {
      ForEach(CloudPresets.all) { Text($0.displayName).tag($0.id) }
      Text("Custom").tag("custom")
    }

    if vendorSelection.wrappedValue == "custom" {
      Picker("Provider Type", selection: Binding(
        get: { cloudFlavor },
        set: { newFlavor in
          cloudFlavorRaw = newFlavor.rawValue
          cloudBaseURL = newFlavor.defaultBaseURL
          resetCloudFieldsForVendorChange()
        }
      )) {
        Text("Anthropic").tag(CloudFlavor.anthropic)
        Text("OpenAI-compatible").tag(CloudFlavor.openAICompatible)
      }

      TextField("Base URL", text: $cloudBaseURL)
        .focused($baseURLFocused)
        .onChange(of: cloudBaseURL) { _, _ in fetchError = false }
        .onChange(of: baseURLFocused) { _, focused in
          if !focused { reloadKeyForAccount(); model.rebuildSummaryBuilder() }
        }
    }

    SecureField("API Key", text: $apiKeyField)
      .focused($keyFocused)
      .onChange(of: apiKeyField) { _, _ in fetchError = false }
      .onSubmit { commitKey() }
      .onChange(of: keyFocused) { _, focused in if !focused { commitKey() } }
      .onDisappear { if apiKeyField != loadedKey { commitKey() } }

    HStack {
      if models.isEmpty {
        TextField("Model", text: $cloudModel)
          .focused($modelFocused)
          .onSubmit { model.rebuildSummaryBuilder() }
          .onChange(of: modelFocused) { _, focused in if !focused { model.rebuildSummaryBuilder() } }
      } else {
        Picker("Model", selection: $cloudModel) {
          ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
        }
        .onChange(of: cloudModel) { _, _ in model.rebuildSummaryBuilder() }
      }
      Button(isFetching ? "Fetching…" : "Fetch models") { fetchModels() }
        .disabled(isFetching || !canFetch)
    }

    if fetchError {
      Label("Couldn’t reach the provider. Check the key and base URL.",
            systemImage: "exclamationmark.triangle")
        .font(.caption).foregroundStyle(.secondary)
    } else if didFetch && !models.isEmpty {
      Text("\(models.count) models available")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  /// Fetched models plus the current value if the picker wouldn't otherwise contain it (so a custom
  /// or stale model still shows selected instead of blank).
  private var modelOptions: [String] {
    (cloudModel.isEmpty || models.contains(cloudModel)) ? models : [cloudModel] + models
  }

  private var canFetch: Bool {
    !cloudBaseURL.isEmpty
      && (!apiKeyField.isEmpty
          || CloudConfig(flavor: cloudFlavor, baseURL: cloudBaseURL, model: cloudModel).isLocalEndpoint)
  }

  /// The Vendor picker's value: the matching preset id, else "custom". Selecting a preset writes its
  /// flavor + base URL; selecting "Custom" keeps the current values and reveals the free fields.
  private var vendorSelection: Binding<String> {
    Binding(
      get: { CloudPresets.match(flavor: cloudFlavor, baseURL: cloudBaseURL)?.id ?? "custom" },
      set: { id in
        guard let preset = CloudPresets.all.first(where: { $0.id == id }) else { return }
        cloudFlavorRaw = preset.flavor.rawValue
        cloudBaseURL = preset.baseURL
        resetCloudFieldsForVendorChange()
      }
    )
  }

  private func resetCloudFieldsForVendorChange() {
    cloudModel = ""; models = []; fetchError = false; didFetch = false
    reloadKeyForAccount()
    model.rebuildSummaryBuilder()
  }

  private func reloadKeyForAccount() {
    apiKeyField = KeychainSecretStore().read(account: keychainAccount) ?? ""
    loadedKey = apiKeyField
  }

  private func commitKey() {
    guard apiKeyField != loadedKey else { return }
    KeychainSecretStore().write(apiKeyField, account: keychainAccount)
    loadedKey = apiKeyField
    model.rebuildSummaryBuilder()
  }

  private func fetchModels() {
    commitKey()
    let config = CloudConfig(flavor: cloudFlavor, baseURL: cloudBaseURL, model: cloudModel)
    let key = apiKeyField
    isFetching = true; fetchError = false
    Task {
      defer { isFetching = false }
      do {
        let fetched = try await CloudLLMProvider.listModels(config: config, apiKey: key)
        models = fetched
        didFetch = true
        if cloudModel.isEmpty, let first = fetched.first {
          cloudModel = first
          model.rebuildSummaryBuilder()
        }
      } catch {
        fetchError = true
      }
    }
  }
}
```

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: BUILD SUCCEEDED. (Any new l10n key not yet in the catalog just falls back to English — added in Task 5.)

- [ ] **Step 3: Smoke-launch the inner binary**

Run:
```bash
PENSIEVE_DB=$(mktemp -u).sqlite PENSIEVE_CAPTURE_DB=$(mktemp -u).sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
APP_PID=$!; sleep 4; kill $APP_PID 2>/dev/null
```
Expected: launches without crashing for ~4s (open ⌘, manually later to eyeball the panel).

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/SettingsView.swift
git commit -F - <<'EOF'
feat(app): vendor presets, prefill, focus-commit, model union, fetch guards

Rewrite the Settings cloud subsection: a Vendor picker over CloudPresets
(flavor + base URL prefilled; Custom reveals the free fields); base-URL
prefill on entering Cloud; commit key/URL/model on focus-loss not per
keystroke; union the current model into the picker; disable Fetch until
reachable; clear the error on edit and show a model count on success.
Friendly localizable provider labels + a per-selection explainer caption.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GYk35bcbwrnKorHstUcYUd
EOF
```

---

### Task 5: Localization — new keys (English base + German)

**Files:**
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: the `LocalizedStringKey` literals introduced in Task 4.

Add each key below to `Localizable.xcstrings`, mirroring the shape of an existing entry (a `strings` map keyed by the source string, each with `localizations.en.stringUnit` and `localizations.de.stringUnit`, `state: "translated"`). Read one existing entry first to copy the exact JSON structure. The catalog is JSON — keep it valid; the key is the **exact** English source string (including curly quotes and `%lld`).

- [ ] **Step 1: Add the new keys**

| Key (English source string) | German (`de`) |
|---|---|
| `On-device (Foundation Models)` | `Auf dem Gerät (Foundation Models)` |
| `Claude CLI (subscription)` | `Claude CLI (Abonnement)` |
| `Picks the best on-device option — Foundation Models when available, otherwise the Claude CLI.` | `Wählt die beste Option auf dem Gerät — Foundation Models, falls verfügbar, sonst die Claude CLI.` |
| `Runs entirely on-device. Private and free, but noticeably lower quality than a frontier cloud model.` | `Läuft vollständig auf dem Gerät. Privat und kostenlos, aber deutlich geringere Qualität als ein modernes Cloud-Modell.` |
| `Uses your Claude subscription via the claude command. Good quality, stays on your account.` | `Nutzt das Claude-Abonnement über den Befehl „claude“. Gute Qualität, bleibt im eigenen Konto.` |
| `Highest quality. Sends recent activity excerpts to the chosen vendor's API.` | `Höchste Qualität. Sendet Auszüge der jüngsten Aktivität an die API des gewählten Anbieters.` |
| `Vendor` | `Anbieter` |
| `Custom` | `Benutzerdefiniert` |
| `%lld models available` | `%lld Modelle verfügbar` |

Notes:
- `Automatic`, `Cloud (API)`, `OpenAI-compatible`, `Anthropic`, `Provider Type`, `Base URL`, `API Key`, `Model`, `Fetch models`, `Fetching…`, and the two warning strings are **already** in the catalog — do not duplicate.
- The old standalone tag strings `Foundation Models` and `claude -p` are now unused as picker labels but remain referenced by the warning string context; leave their existing entries untouched (harmless if orphaned).

- [ ] **Step 2: Build and confirm the catalog compiles into the bundle**

Run: `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Then confirm the German strings file exists and contains a new key:
```bash
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -i "Anbieter"
```
Expected: BUILD SUCCEEDED and the `grep` prints the `Vendor = "Anbieter"` line (proves the `de` value made it into the bundle, not an English fallback).

- [ ] **Step 3: Forced-locale smoke-launch (eyeball German)**

Run:
```bash
PENSIEVE_DB=$(mktemp -u).sqlite PENSIEVE_CAPTURE_DB=$(mktemp -u).sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve -AppleLanguages '(de)' &
APP_PID=$!; sleep 4; kill $APP_PID 2>/dev/null
```
Expected: launches; open ⌘, manually to confirm the provider labels/captions render in German (human-verify carry).

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(app): localize provider labels, explainer captions, and cloud chrome (de)

Add German for the friendly provider labels, per-selection help captions,
"Vendor"/"Custom", and the "N models available" count.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GYk35bcbwrnKorHstUcYUd
EOF
```

---

### Task 6: Full-suite regression + final build

**Files:** none (verification only).

- [ ] **Step 1: Run the whole Kit test suite**

Run: `./scripts/test.sh`
Expected: PASS, count = 260 (pre-existing) + new tests from Tasks 1–2. Note the new total.

- [ ] **Step 2: Clean app build**

Run: `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Discard transient Package.resolved churn if any**

Run: `git status` — if `Package.resolved` changed only from the xcodebuild, `git checkout -- **/Package.resolved` (do not commit xcodebuild dependency churn).

- [ ] **Step 4: Human-verify carries (note in the PR / CONTINUE.md, do not block)**
  - ⌘, → pick each provider; confirm the explainer caption changes and reads correctly.
  - Select Cloud → Vendor = OpenAI: base URL auto-fills; enter a key; Fetch → model list populates + "N models available".
  - Switch Vendor OpenAI → Groq: key field clears (per-vendor slot), base URL updates.
  - Vendor = Ollama with a local server running: Fetch works with an empty key; narration uses it.
  - Vendor = Custom: flavor picker + free base URL reappear (today's behavior).
  - Forced German (`-AppleLanguages '(de)'`): labels/captions localized; vendor names stay English.

---

## Self-Review

**Spec coverage:**
- §A IA (nested, 4-option top picker) → Task 4 (picker + `cloudSection`). ✓
- §B presets (`CloudPreset`/`all`/`match`) + per-vendor keychain → Task 2; consumed in Tasks 3–4. ✓
- §C keyless localhost + `apiKey ?? ""` crash fix → Task 1. ✓
- §D friendly labels + per-selection explainer + localizable flavor label → Task 4 (literals) + Task 5 (catalog). ✓
- §E polish (prefill+mismatch, commit-not-keystroke, robust key commit, model union, fetch affordances) → Task 4; `cloudInputs` fallback → Task 3. ✓
- §F tests (presets/match/Custom, isLocalEndpoint, resolver keyless localhost vs remote) → Tasks 1–2. ✓

**Placeholder scan:** no TBD/TODO; every code step shows full code; every command has an expected result. ✓

**Type consistency:** `CloudPresets.all/match/keychainAccount`, `CloudPreset.{id,displayName,flavor,baseURL}`, `CloudConfig.isLocalEndpoint` used identically across Tasks 1–4. Keychain account string `"custom.<flavor>"` matches between `CloudPresets.keychainAccount` (Task 2) and its consumers (Tasks 3–4). Cache-key format `cloud:<account>:<model>` defined once (Task 3). ✓
