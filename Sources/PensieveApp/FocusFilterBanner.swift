// Sources/PensieveApp/FocusFilterBanner.swift
import SwiftUI

/// Says out loud that a Focus filter is scoping what the middle column shows.
///
/// Without it the filter is invisible: `PensieveFocusFilter` writes a context into UserDefaults and
/// `AppModel.refresh()` quietly drops every node outside it — from the list, the briefing, the
/// counts and the search results — leaving a short list that reads as "not much going on" rather
/// than "you are only being shown half of it". This is the Mail treatment for the same problem.
///
/// Indicative only, deliberately: there is no public API for a third-party app to turn its own Focus
/// filter off, and an app-local override that quietly disagreed with the system's idea of the active
/// Focus would be a second source of truth for the state this banner exists to report. Turning the
/// Focus off stays in Control Center, where the user set it.
struct FocusFilterBanner: View {
  /// The active Focus context ("" = no Focus, and the banner renders nothing).
  let context: String

  var body: some View {
    if !context.isEmpty {
      HStack(spacing: 5) {
        // Decorative — the text beside it already says "Focus", so VoiceOver would hear it twice.
        Image(systemName: "moon.fill").imageScale(.small).accessibilityHidden(true)
        // `context` is user Focus-context data, not chrome — interpolated verbatim, never localized,
        // matching the widget header's rule for the same value.
        Text("Filtered by Focus · \(context)")
        Spacer(minLength: 0)
      }
      .font(.caption).fontWeight(.medium)
      .foregroundStyle(.purple)
      .padding(.horizontal, 12).padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.bar)
      .overlay(alignment: .bottom) { Divider() }
    }
  }
}
