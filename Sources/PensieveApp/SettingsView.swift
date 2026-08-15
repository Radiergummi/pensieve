import SwiftUI
import PensieveKit

/// The app's Settings pane (⌘,) — a native multi-pane TabView, the first-party settings pattern.
/// The window sizes to the visible tab; each tab carries its own .frame(width: 460).
struct SettingsView: View {
  var model: AppModel

  var body: some View {
    TabView {
      GeneralSettingsTab()
        .tabItem { Label("General", systemImage: "gearshape") }
      IntelligenceSettingsTab(model: model)
        .tabItem { Label("Intelligence", systemImage: "sparkles") }
      TranslationSettingsTab(model: model)
        .tabItem { Label("Translation", systemImage: "translate") }
      AdvancedSettingsTab(model: model)
        .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
    }
  }
}
