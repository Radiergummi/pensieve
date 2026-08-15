import SwiftUI
import AppKit
import ServiceManagement
import PensieveKit

/// Settings ▸ Advanced. A read-only diagnostics glance: resolved provider, background-sync status,
/// and the store paths. Re-gathers the tested `SystemStatusGatherer` kernel every few seconds while
/// visible (the gather is a cheap file-stat + one-row DB read), so "Last sync" / "Last captured
/// activity" stay live. It never mutates the agent — the toggle lives in Settings ▸ General.
struct AdvancedSettingsTab: View {
  var model: AppModel

  @State private var status: SystemStatus?
  @State private var syncStatus: SMAppService.Status = .notRegistered
  @State private var isInspectorPresented = false

  /// SwiftUI-observed rather than a bare `UserDefaults` read, matching `SupportFolderInspector`'s
  /// own backing store — both share `PensieveDefaults.isCustomSupportRoot` for the actual rule
  /// rather than each restating "is it non-empty".
  @AppStorage(PensieveDefaults.customSupportRootKey) private var customSupportRootRaw = ""
  private var isCustomRoot: Bool { PensieveDefaults.isCustomSupportRoot(customSupportRootRaw) }

  var body: some View {
    Form {
      Section("Status") {
        LabeledContent("LLM provider") { Text(providerDisplayName) }
        if let status, !status.foundationModelsAvailable {
          Label("Foundation Models isn’t available on this Mac.", systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
        }
        LabeledContent("Background sync") { Text(syncStatusText) }
        LabeledContent("Last sync") { Text(relative(status?.lastSyncAt)) }
        LabeledContent("Last captured activity") { Text(relative(status?.lastEventAt)) }
      }

      Section("Store & Logs") {
        LocationRow(title: "Support folder",
                    url: PensievePaths.supportDirectory(),
                    status: isCustomRoot ? "Custom" : "Default",
                    onInspect: { isInspectorPresented = true })
        LocationRow(title: "Canonical store", url: resolvedCanonicalURL())
        LocationRow(title: "Capture spool", url: resolvedSpoolURL())
        LocationRow(title: "Logs", url: PensievePaths.logsDirectory())
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .sheet(isPresented: $isInspectorPresented) { SupportFolderInspector() }
    .task {
      // Poll while the tab is visible; `.task` cancels on disappear. Keeps the relative
      // times ("2 minutes ago") and the agent status honest without a resident observer.
      while !Task.isCancelled {
        load()
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }

  /// The live SMAppService registration state, in human words (mirrors the General status line).
  private var syncStatusText: LocalizedStringKey {
    switch syncStatus {
    case .enabled: return "Enabled"
    case .requiresApproval: return "Needs approval"
    case .notRegistered: return "Off"
    case .notFound: return "Not found"
    @unknown default: return "Off"
    }
  }

  private func load() {
    syncStatus = BackgroundSyncService.status
    let (config, key) = model.cloudInputs()
    status = SystemStatusGatherer.gather(
      database: model.database,
      provider: ProviderInputs(defaults: .standard, cloudConfig: config, apiKey: key),
      backgroundSyncEnabled: syncStatus == .enabled,
      syncLogURL: PensievePaths.syncLogURL())
  }

  /// The RESOLVED kind, in human words. The raw kind strings are never shown and never localized.
  private var providerDisplayName: LocalizedStringKey {
    switch status?.providerKind {
    case "foundationModels": return "On-device (Foundation Models)"
    case "claudeCLI": return "Claude CLI (subscription)"
    case "cloud": return "Cloud (API)"
    default: return "—"
    }
  }

  /// An honest em-dash-free absent value: "Never" reads as a fact, not a formatting failure.
  private func relative(_ date: Date?) -> String {
    guard let date else { return String(localized: "Never") }
    return date.formatted(.relative(presentation: .named))
  }
}
