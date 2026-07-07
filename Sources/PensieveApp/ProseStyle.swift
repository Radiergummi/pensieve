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
}
