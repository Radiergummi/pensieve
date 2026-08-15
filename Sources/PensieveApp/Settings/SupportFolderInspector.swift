import AppKit
import SwiftUI
import PensieveKit

/// The ⓘ sheet for the support folder: current location, size on disk, and the Default/Custom
/// switch that triggers a verified move.
///
/// Choosing `Custom` picks a CONTAINER and Pensieve uses `<chosen>/Pensieve`, shown in full in the
/// confirmation before anything happens. A deliberate deviation from Xcode: picking `/Volumes/Work`
/// and being refused for "not empty" would be maddening, and the appended component mirrors the
/// default layout exactly.
struct SupportFolderInspector: View {
  @Environment(\.dismiss) private var dismiss

  @State private var pendingDestination: URL?
  @State private var refusal: String?
  @State private var measuredBytes: Int64 = 0

  private var currentRoot: URL { PensievePaths.supportDirectory() }
  private var isCustom: Bool {
    PensieveDefaults.shared().string(forKey: PensieveDefaults.customSupportRootKey)?
      .isEmpty == false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Form {
        LabeledContent("Location") {
          Picker("Location", selection: locationBinding) {
            Text("Default").tag(false)
            Text("Custom").tag(true)
          }
          .labelsHidden()
          .fixedSize()
        }
        Text(verbatim: currentRoot.path)        // content — never localized
          .font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        Text(byteText).font(.callout).foregroundStyle(.secondary)
        if let refusal {
          Label(refusal, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 420)
    .task { measuredBytes = StoreRelocator.directorySize(at: currentRoot) }
    .confirmationDialog(confirmationTitle, isPresented: confirmationBinding) {
      Button("Move and Relaunch") {
        if let pendingDestination { RelocationLauncher.requestRelocation(to: pendingDestination) }
      }
      Button("Cancel", role: .cancel) { pendingDestination = nil }
    } message: {
      Text("\(byteText) will be copied. The old folder is moved to the Bin after verification, and Pensieve relaunches.")
    }
  }

  private var byteText: String {
    measuredBytes.formatted(.byteCount(style: .file))
  }

  private var confirmationTitle: String {
    guard let pendingDestination else { return "" }
    return String(localized: "Move Pensieve’s data to \(pendingDestination.path)?")
  }

  private var confirmationBinding: Binding<Bool> {
    Binding(get: { pendingDestination != nil },
            set: { if !$0 { pendingDestination = nil } })
  }

  private var locationBinding: Binding<Bool> {
    Binding(get: { isCustom }, set: { wantsCustom in
      refusal = nil
      if wantsCustom {
        chooseCustomFolder()
      } else {
        proposeMove(to: PensievePaths.defaultSupportDirectory())
      }
    })
  }

  private func chooseCustomFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = String(localized: "Choose")
    guard panel.runModal() == .OK, let container = panel.url else { return }
    proposeMove(to: container.appendingPathComponent("Pensieve", isDirectory: true))
  }

  /// Pre-flight first, so a bad destination is refused by name instead of failing mid-copy.
  private func proposeMove(to destination: URL) {
    if let error = StoreRelocator.preflight(source: currentRoot, destination: destination) {
      refusal = Self.message(for: error, measuredBytes: measuredBytes)
      return
    }
    pendingDestination = destination
  }

  /// Each refusal names its own reason. A generic failure would leave the user guessing which of
  /// several different mistakes they made.
  static func message(for error: RelocationError, measuredBytes: Int64) -> String {
    switch error {
    case .destinationIsSource:
      return String(localized: "Pensieve already uses that folder.")
    case .destinationInsideSource:
      return String(localized: "Choose a folder outside Pensieve’s current one.")
    case .destinationNotEmpty:
      return String(localized: "That folder already contains a Pensieve folder with files in it.")
    case .destinationAlreadyExists:
      return String(localized: "An empty folder already exists there. Remove it first.")
    case .destinationNotADirectory:
      return String(localized: "That’s a file, not a folder.")
    case .destinationNotWritable:
      return String(localized: "Pensieve can’t write to that folder.")
    case .insufficientSpace:
      return String(localized: "There isn’t enough free space on that disk.")
    case .lockUnavailable:
      return String(localized: "A sync is running. Try again in a moment.")
    case .verificationFailed:
      return String(localized: "The copied data didn’t verify. Nothing was changed.")
    }
  }
}
