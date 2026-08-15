import AppKit
import SwiftUI

/// One filesystem location, in the shape Xcode's Locations pane uses: title and status on the
/// first line, the path on its own line below.
///
/// The path is NOT monospaced and NOT middle-truncated. The previous single-line row rendered
/// `/Users/moritz/Library…nsieve/pensieve.sqlite`, which is neither readable nor selectable — the
/// real path survived only in a tooltip. Monospace made it worse: wider per glyph, and nothing
/// here needs column alignment.
struct LocationRow: View {
  let title: LocalizedStringKey
  let url: URL
  /// `Default` / `Custom`, or nil for a derived location that cannot be configured.
  var status: LocalizedStringKey?
  /// nil for derived locations — an ⓘ opening a modal with no controls would be a lie about
  /// what is configurable.
  var onInspect: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(title)
        Spacer()
        if let status {
          Text(status).foregroundStyle(.secondary)
        }
        if let onInspect {
          Button(action: onInspect) { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .help("Show details")
        }
      }
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(verbatim: url.path)         // a path is content — never localized
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
          Image(systemName: "arrow.right")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.link)
        .help("Reveal in Finder")
      }
    }
  }
}
