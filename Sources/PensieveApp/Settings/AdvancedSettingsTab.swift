import SwiftUI
import AppKit
import ServiceManagement
import PensieveKit

/// Settings ▸ Advanced. Resolved provider, the background-sync control + status, and the store
/// paths. Reads the tested `SystemStatusGatherer` kernel once on appear; the background-sync toggle
/// is the single control (register/unregister via `BackgroundSyncService`).
struct AdvancedSettingsTab: View {
  @ObservedObject var model: AppModel

  @AppStorage(AppDefaults.backgroundSyncEnabledKey) private var backgroundSyncEnabled = true
  @State private var status: SystemStatus?
  @State private var syncStatus: SMAppService.Status = .notRegistered

  var body: some View {
    Form {
      Section("Status") {
        LabeledContent("LLM provider") { Text(providerDisplayName) }
        if let status, !status.foundationModelsAvailable {
          Label("Foundation Models isn’t available on this Mac.", systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
        }
        LabeledContent("Last sync") { Text(relative(status?.lastSyncAt)) }
        LabeledContent("Last captured activity") { Text(relative(status?.lastEventAt)) }
      }

      Section("Background sync") {
        Toggle("Keep Pensieve synced in the background", isOn: $backgroundSyncEnabled)
          .onChange(of: backgroundSyncEnabled) { _, on in
            if on { BackgroundSyncService.registerIfNeeded() } else { BackgroundSyncService.unregister() }
            syncStatus = BackgroundSyncService.status
          }
        LabeledContent("Status") { Text(syncStatusText) }
        if syncStatus == .requiresApproval {
          Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
        }
      }

      Section("Store & Logs") {
        pathRow("Canonical store", Stores.canonicalURL)
        pathRow("Capture spool", Stores.spoolURL)
        pathRow("Support folder", PensievePaths.supportDirectory())
        pathRow("Logs", PensievePaths.logsDirectory())
        Button("Open Logs Folder") {
          NSWorkspace.shared.open(PensievePaths.logsDirectory())
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .onAppear(perform: load)
  }

  /// The live SMAppService registration state, in human words (mirrors the Settings status line).
  private var syncStatusText: LocalizedStringKey {
    switch syncStatus {
    case .enabled: return "Enabled"
    case .requiresApproval: return "Needs approval"
    case .notRegistered: return "Off"
    case .notFound: return "Not found"
    @unknown default: return "Off"
    }
  }

  /// A full store path does NOT fit 460 pt — truncate in the middle and put the whole path in a
  /// tooltip, so the row can never blow out the window.
  @ViewBuilder private func pathRow(_ title: LocalizedStringKey, _ url: URL) -> some View {
    LabeledContent(title) {
      HStack(spacing: 8) {
        Text(url.path)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(url.path)
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .buttonStyle(.link)
        .fixedSize()
      }
    }
  }

  private func load() {
    syncStatus = BackgroundSyncService.status
    let (config, key) = model.cloudInputs()
    status = SystemStatusGatherer.gather(db: model.db,
                                         defaults: .standard,
                                         cloudConfig: config,
                                         apiKey: key,
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
