import SwiftUI
import AppKit
import ServiceManagement
import PensieveKit

/// Settings ▸ General. Intentionally short — standard macOS General tabs often are.
struct GeneralSettingsTab: View {
  @AppStorage(AppDefaults.hideDockIconKey) private var hideDockIcon = false
  @AppStorage(AppDefaults.backgroundSyncEnabledKey) private var backgroundSyncEnabled = true
  @State private var syncStatus: SMAppService.Status = .notRegistered
  @State private var cliPlan: CLIToolInstaller.Plan = .create
  @State private var showReplaceConfirm = false

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
          .onChange(of: backgroundSyncEnabled) { _, newEnabled in
            // Registering is asynchronous, so its status must be read AFTER it completes; reading
            // through would report the pre-registration state. Unregistering is synchronous.
            if newEnabled {
              Task { @MainActor in syncStatus = await BackgroundSyncService.register() }
            } else {
              BackgroundSyncService.unregister()
              syncStatus = BackgroundSyncService.status
            }
          }
        LabeledContent("Status") { Text(statusText) }
        if syncStatus == .requiresApproval {
          Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
        }
      }

      Section("Command-line tool") {
        LabeledContent("Status") { Text(cliStatusText) }
        switch cliPlan {
        case .create:
          Button("Install command-line tool") { applyCLI(.create) }
        case .repoint:
          Button("Repair") { applyCLI(.repoint) }
        case .blockedRealFile:
          Button("Replace existing binary") { showReplaceConfirm = true }
            .confirmationDialog(
              "Replace the pensieve binary in ~/.local/bin with a link to the app’s copy?",
              isPresented: $showReplaceConfirm, titleVisibility: .visible) {
                Button("Replace", role: .destructive) { replaceCLI() }
                Button("Cancel", role: .cancel) {}
              }
        case .upToDate:
          EmptyView()
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .onAppear {
      syncStatus = BackgroundSyncService.status
      cliPlan = currentCLIPlan()
    }
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

  private var cliStatusText: LocalizedStringKey {
    switch cliPlan {
    case .upToDate: return "Installed"
    case .create: return "Not installed"
    case .repoint: return "Points elsewhere"
    case .blockedRealFile: return "A file is in the way"
    }
  }

  private var cliLink: URL { PensievePaths.installedBinaryURL() }
  private var cliTarget: URL { CLIToolInstaller.bundledCLIURL(appBundleURL: Bundle.main.bundleURL) }

  private func currentCLIPlan() -> CLIToolInstaller.Plan {
    CLIToolInstaller.plan(linkPath: cliLink, desiredTarget: cliTarget)
  }

  private func applyCLI(_ plan: CLIToolInstaller.Plan) {
    try? CLIToolInstaller.apply(plan, linkPath: cliLink, desiredTarget: cliTarget)
    cliPlan = currentCLIPlan()
  }

  private func replaceCLI() {
    try? CLIToolInstaller.replace(linkPath: cliLink, desiredTarget: cliTarget)
    cliPlan = currentCLIPlan()
  }
}
