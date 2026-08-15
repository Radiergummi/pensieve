import SwiftUI

/// Shown instead of the main window while a launch-time relocation runs. Determinate, because the
/// copy's progress is genuinely known and an indeterminate spinner over a 130 MB copy reads as a
/// hang.
struct RelocationProgressView: View {
  let destination: String
  let fraction: Double
  let failure: String?
  /// True only when the relocation fully succeeded and committed, but rows were still pending in
  /// the old spool afterwards, so the old folder was deliberately kept instead of moved to the
  /// Trash. This is a normal outcome (a session transcript still inside its grace window), never an
  /// error — it must render as success, not alongside `failure`'s wording.
  var recoveryIncomplete = false
  var onContinue: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let failure {
        Label("Moving Pensieve’s data failed", systemImage: "exclamationmark.triangle")
          .font(.headline)
        Text(failure).font(.callout).foregroundStyle(.secondary)
        Text("Pensieve is still using its previous location. Nothing was lost.")
          .font(.callout).foregroundStyle(.secondary)
      } else if recoveryIncomplete {
        Label("Pensieve’s data was moved", systemImage: "checkmark.circle")
          .font(.headline)
        Text("Some captured work was still pending, so the previous location was kept.")
          .font(.callout).foregroundStyle(.secondary)
        if let onContinue {
          Button("Continue") { onContinue() }
            .keyboardShortcut(.defaultAction)
        }
      } else {
        Text("Moving Pensieve’s data…").font(.headline)
        ProgressView(value: fraction)
        Text(verbatim: destination)     // a path is content — never localized
          .font(.callout).foregroundStyle(.secondary).lineLimit(2)
      }
    }
    .padding(24)
    .frame(width: 420)
  }
}
