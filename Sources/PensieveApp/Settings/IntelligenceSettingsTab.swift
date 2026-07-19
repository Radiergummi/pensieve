import SwiftUI
import PensieveKit

/// Settings ▸ Intelligence. The narration toggle, the provider picker, and the cloud subsection —
/// moved verbatim out of the old single-Form SettingsView and given vertical room. Reads/writes
/// preferences via @AppStorage; the only AppModel touch is rebuilding its summary builder on change.
struct IntelligenceSettingsTab: View {
  var model: AppModel
  @AppStorage(PensieveDefaults.llmProviderKey) private var providerRaw = ProviderPreference.auto.rawValue
  @AppStorage(AppDefaults.narrationEnabledKey) private var narrationEnabled = true
  @AppStorage(PensieveDefaults.semanticSearchKey) private var semanticSearchEnabled = true

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
  @State private var vendorIsCustom = false

  @FocusState private var keyFocused: Bool
  @FocusState private var baseURLFocused: Bool
  @FocusState private var modelFocused: Bool

  private var foundationAvailable: Bool { FoundationModelsProbe.isAvailable() }
  private var cloudFlavor: CloudFlavor { CloudFlavor(rawValue: cloudFlavorRaw) ?? .anthropic }
  private var keychainAccount: String {
    // keychainAccount normalizes an empty base URL to the flavor default itself, so both the app and
    // AppModel key off the identical URL without each re-implementing the normalization.
    CloudPresets.keychainAccount(flavor: cloudFlavor, baseURL: cloudBaseURL)
  }

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
      Section {
        Toggle("Show “Last Work Done” narration", isOn: $narrationEnabled)

        Toggle("Semantic search (find by meaning)", isOn: $semanticSearchEnabled)
        Text("Builds an on-device index so ⌘F and Claude Code can find work by meaning, not just exact words. First use downloads a small on-device model.")
          .font(.caption).foregroundStyle(.secondary)

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
      }

      if provider.wrappedValue == .cloud {
        Section("Cloud provider") { cloudSection }
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
        .onChange(of: cloudBaseURL) { _, _ in fetchError = false; models = [] }
        .onChange(of: baseURLFocused) { _, focused in
          if !focused { reloadKeyForAccount(); model.rebuildSummaryBuilder() }
        }
    }

    SecureField("API Key", text: $apiKeyField)
      .focused($keyFocused)
      .onChange(of: apiKeyField) { _, _ in fetchError = false }
      .onSubmit { commitKey() }
      .onChange(of: keyFocused) { _, focused in if !focused { commitKey() } }
      .onDisappear { commitKey() }

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
    } else if !models.isEmpty {
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
      get: { vendorIsCustom ? "custom" : (CloudPresets.match(flavor: cloudFlavor, baseURL: cloudBaseURL)?.id ?? "custom") },
      set: { id in
        if id == "custom" {
          vendorIsCustom = true          // leave flavor/URL as-is; reveal the free fields
          fetchError = false
          return
        }
        guard let preset = CloudPresets.all.first(where: { $0.id == id }) else { return }
        vendorIsCustom = false
        cloudFlavorRaw = preset.flavor.rawValue
        cloudBaseURL = preset.baseURL
        resetCloudFieldsForVendorChange()
      }
    )
  }

  private func resetCloudFieldsForVendorChange() {
    cloudModel = ""; models = []; fetchError = false
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
