import SwiftUI
import AppKit
import ServiceManagement
import PensieveKit

/// Settings ▸ General. Intentionally short — standard macOS General tabs often are.
struct GeneralSettingsTab: View {
  @AppStorage(AppDefaults.hideDockIconKey) private var hideDockIcon = false
  @AppStorage(AppDefaults.backgroundSyncEnabledKey) private var backgroundSyncEnabled = true
  @State private var syncStatus: SMAppService.Status = .notRegistered

  var body: some View {
    Form {
      Section {
        Toggle("Hide Dock icon (menu bar only)", isOn: $hideDockIcon)
          .onChange(of: hideDockIcon) { _, hidden in
            NSApp.setActivationPolicy(hidden ? .accessory : .regular)
            if !hidden { NSApp.activate(ignoringOtherApps: true) }
          }
      }

      Section("Background sync") {
        Toggle("Keep Pensieve synced in the background", isOn: $backgroundSyncEnabled)
          .onChange(of: backgroundSyncEnabled) { _, on in
            if on { BackgroundSyncService.registerIfNeeded() } else { BackgroundSyncService.unregister() }
            syncStatus = BackgroundSyncService.status
          }
        LabeledContent("Status") { Text(statusText) }
        if syncStatus == .requiresApproval {
          Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .onAppear { syncStatus = BackgroundSyncService.status }
  }

  private var statusText: LocalizedStringKey {
    switch syncStatus {
    case .enabled: return "Enabled"
    case .requiresApproval: return "Needs approval"
    case .notRegistered: return "Off"
    case .notFound: return "Not found"
    @unknown default: return "Off"
    }
  }
}
