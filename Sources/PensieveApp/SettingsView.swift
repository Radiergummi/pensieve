import SwiftUI
import PensieveKit

/// The app's Settings pane (⌘,). Reads/writes the machine-local Preferences directly — no
/// @Published mirror on AppModel; the only AppModel touch is rebuilding its summary builder
/// when the provider changes.
struct SettingsView: View {
  @ObservedObject var model: AppModel
  @State private var provider: ProviderPreference = Preferences.read(from: Stores.preferencesURL)

  private var foundationAvailable: Bool { FoundationModelsProbe.isAvailable() }

  var body: some View {
    Form {
      Section("Intelligence") {
        Picker("LLM Provider", selection: $provider) {
          Text("Automatic").tag(ProviderPreference.auto)
          Text("Foundation Models").tag(ProviderPreference.foundationModels)
          Text("claude -p").tag(ProviderPreference.claudeCLI)
        }
        .onChange(of: provider) { _, newValue in
          Preferences.write(newValue, to: Stores.preferencesURL)
          model.rebuildSummaryBuilder()
        }
        if provider == .foundationModels && !foundationAvailable {
          Label("Foundation Models isn’t available on this Mac — using claude -p instead.",
                systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
  }
}
