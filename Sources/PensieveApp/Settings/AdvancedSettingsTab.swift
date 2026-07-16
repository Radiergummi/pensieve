import SwiftUI
import AppKit
import ServiceManagement
import PensieveKit

/// Settings ▸ Advanced. A read-only glance: resolved provider, background-sync status, and the store
/// paths. Reads the tested `SystemStatusGatherer` kernel once on appear — no live observation, and
/// it never mutates the agent (the toggle lives in Settings ▸ General).
struct AdvancedSettingsTab: View {
  @ObservedObject var model: AppModel

  @State private var status: SystemStatus?

  var body: some View {
    Form {
      Section("Status") {
        LabeledContent("LLM provider") { Text(providerDisplayName) }
        if let status, !status.foundationModelsAvailable {
          Label("Foundation Models isn’t available on this Mac.", systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
        }
        LabeledContent("Background sync") {
          Text(status?.backgroundSyncEnabled == true ? "Enabled" : "Off")
        }
        LabeledContent("Last sync") { Text(relative(status?.lastSyncAt)) }
        LabeledContent("Last captured activity") { Text(relative(status?.lastEventAt)) }
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
    let (config, key) = model.cloudInputs()
    status = SystemStatusGatherer.gather(db: model.db,
                                         defaults: .standard,
                                         cloudConfig: config,
                                         apiKey: key,
                                         backgroundSyncEnabled: BackgroundSyncService.status == .enabled,
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
