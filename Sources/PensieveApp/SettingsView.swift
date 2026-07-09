import SwiftUI
import AppKit
import PensieveKit

/// The app's Settings pane (⌘,). Reads/writes the provider preference via @AppStorage — no
/// @Published mirror on AppModel; the only AppModel touch is rebuilding its summary builder
/// when the provider changes.
struct SettingsView: View {
  @ObservedObject var model: AppModel
  @AppStorage(PensieveDefaults.llmProviderKey) private var providerRaw = ProviderPreference.auto.rawValue
  @AppStorage(AppDefaults.hideDockIconKey) private var hideDockIcon = false
  @AppStorage(AppDefaults.narrationEnabledKey) private var narrationEnabled = true

  private var foundationAvailable: Bool { FoundationModelsProbe.isAvailable() }

  private var provider: Binding<ProviderPreference> {
    Binding(
      get: { ProviderPreference(rawValue: providerRaw) ?? .auto },
      set: { providerRaw = $0.rawValue }
    )
  }

  @AppStorage(PensieveDefaults.cloudFlavorKey) private var cloudFlavorRaw = CloudFlavor.anthropic.rawValue
  @AppStorage(PensieveDefaults.cloudBaseURLKey) private var cloudBaseURL = ""
  @AppStorage(PensieveDefaults.cloudModelKey) private var cloudModel = ""
  @State private var apiKeyField = ""
  @State private var models: [String] = []
  @State private var isFetching = false
  @State private var fetchError = false

  private var cloudFlavor: CloudFlavor { CloudFlavor(rawValue: cloudFlavorRaw) ?? .anthropic }

  var body: some View {
    Form {
      Section("General") {
        Toggle("Hide Dock icon (menu bar only)", isOn: $hideDockIcon)
          .onChange(of: hideDockIcon) { _, hidden in
            NSApp.setActivationPolicy(hidden ? .accessory : .regular)
            if !hidden {
              // Returning to .regular: re-front the app, or it can stay backgrounded with no
              // key window.
              NSApp.activate(ignoringOtherApps: true)
            }
          }
      }
      Section("Intelligence") {
        Toggle("Show “Last Work Done” narration", isOn: $narrationEnabled)
        Picker("LLM Provider", selection: provider) {
          Text("Automatic").tag(ProviderPreference.auto)
          Text("Foundation Models").tag(ProviderPreference.foundationModels)
          Text("claude -p").tag(ProviderPreference.claudeCLI)
          Text("Cloud (API)").tag(ProviderPreference.cloud)
        }
        .onChange(of: providerRaw) { _, _ in
          model.rebuildSummaryBuilder()
        }
        if provider.wrappedValue == .foundationModels && !foundationAvailable {
          Label("Foundation Models isn’t available on this Mac — using claude -p instead.",
                systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .onAppear { apiKeyField = KeychainSecretStore().read(account: cloudFlavor.rawValue) ?? "" }
  }

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
}
