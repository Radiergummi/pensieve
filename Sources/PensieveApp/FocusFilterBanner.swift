// Sources/PensieveApp/FocusFilterBanner.swift
import SwiftUI
import PensieveKit

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
        Text("Filtered by Focus · \(localizedContext)")
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

  /// The context is chrome, not captured content: it names one of the two contexts the app itself
  /// writes, and the organizing picker that sets it is localized — so interpolating the raw value
  /// left a bare "work" sitting in German chrome. Reuses that picker's catalog keys rather than
  /// adding new ones, which is also why no new German had to be written for this.
  ///
  /// Note this names the CONTEXT, never the Focus. A Focus of any name — including a custom one —
  /// reaches Pensieve only by picking Work or Personal in the filter's parameter, and no public API
  /// hands an app the active Focus's own display name.
  ///
  /// So only "work" and "personal" can arrive here: that parameter is a two-case `AppEnum`, and
  /// `PensieveFocusFilter.perform()` is the only writer of the default this reads. The fallback is
  /// what Swift asks of a `String` switch, not a case that occurs.
  private var localizedContext: String {
    switch context {
    case NodeContext.work: return String(localized: "Work")
    case NodeContext.personal: return String(localized: "Personal")
    default: return context
    }
  }
}
