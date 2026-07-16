import SwiftUI
import AppKit
import PensieveKit

/// Settings ▸ General. Intentionally short — standard macOS General tabs often are. (The
/// background-sync control lives in Settings ▸ Advanced, next to the sync diagnostics.)
struct GeneralSettingsTab: View {
  @AppStorage(AppDefaults.hideDockIconKey) private var hideDockIcon = false

  var body: some View {
    Form {
      Section {
        Toggle("Hide Dock icon (menu bar only)", isOn: $hideDockIcon)
          .onChange(of: hideDockIcon) { _, hidden in
            NSApp.setActivationPolicy(hidden ? .accessory : .regular)
            if !hidden { NSApp.activate(ignoringOtherApps: true) }
          }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
  }
}
