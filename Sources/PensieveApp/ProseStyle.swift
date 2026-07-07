// Sources/PensieveApp/ProseStyle.swift
import SwiftUI

/// Shared reading-prose treatment for the app's content text (LLM narration, node descriptions,
/// loose-end text/quotes, activity summaries, briefing teasers). App-only styling; no Kit involvement.
enum Prose {
  /// Max reading-column width. Caps line length on wide windows so prose stays readable.
  static let measure: CGFloat = 680
}

extension View {
  /// Body prose: a slightly larger size with generous leading. Apply to text runs, not headers.
  func prose() -> some View {
    self.font(.system(size: 14)).lineSpacing(4)
  }
  /// Section eyebrow (uppercased, tracked). One consistent treatment for every content section
  /// header (Detail's Last Work Done / Loose Ends / Recent Activity, Inspector's Provenance,
  /// Briefing's Moved / Quiet).
  func sectionHeader() -> some View {
    self.font(.system(size: 13, weight: .semibold))
      .textCase(.uppercase)
      .tracking(0.6)
      .foregroundStyle(.secondary)
  }
  /// Small metadata (timestamps, roles, source labels, dormancy). One caption treatment.
  func metaText() -> some View {
    self.font(.footnote).foregroundStyle(.secondary)
  }
}
