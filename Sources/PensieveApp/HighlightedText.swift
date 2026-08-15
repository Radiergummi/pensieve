// Sources/PensieveApp/HighlightedText.swift
import SwiftUI
import PensieveKit

/// Which visual treatment `HighlightedText` gives its `.match` runs. Two shipped looks share the
/// same run-composition machinery rather than living in two renderers:
enum HighlightedTextStyle {
  /// In-place find highlight: every match tints faint yellow; the CURRENT match tints strongly
  /// (full yellow, black foreground — legible in both light and dark appearance).
  case find
  /// The shipped search-snippet look — bold, `.accentColor`, no background. A snippet carries at
  /// most one match, so there is no "current match" concept under this style; `currentOffset` is
  /// ignored.
  case snippet
}

/// The app's ONE highlight renderer: it appends each `FindRun` to a single `AttributedString`, so
/// there is still no index math — the runs arrive already split, and styling is applied to each as
/// it is appended. Defaults to the find style, since that is the style every call site written for
/// in-node find already assumes.
///
/// This was a `Text + Text` concatenation until `+` was deprecated in macOS 26. Styling moved onto
/// the attributes that already carried the `.find` tint: `Text.background(_:)` never worked here
/// anyway (it resolves to the generic `View.background(_:)`, which returns `ModifiedContent`, not
/// `Text`), so the background always came from `AttributedString.backgroundColor`. Bold is carried
/// by `inlinePresentationIntent`, NOT by the `font` attribute: this SDK's SwiftUI attribute scope
/// has no `fontWeight`/`fontDesign` (both were probed and fail to resolve), and setting `font`
/// outright would name a size and so override whatever the call site applies (`.prose()`,
/// `.font(.caption)`, …). The presentation intent styles the run while leaving size inherited.
struct HighlightedText: View {
  let runs: [FindRun]
  /// Character offset of the current match within this text, when it lives here. Ignored under
  /// `.snippet` style.
  var currentOffset: Int?
  var style: HighlightedTextStyle = .find

  var body: some View { Text(composed) }

  private var composed: AttributedString {
    var result = AttributedString()
    var offset = 0
    for run in runs {
      switch run {
      case .plain(let text):
        result += AttributedString(text)
      case .match(let text):
        result += matchRun(text, offset: offset)
      }
      offset += run.text.count
    }
    return result
  }

  private func matchRun(_ text: String, offset: Int) -> AttributedString {
    var attributed = AttributedString(text)
    attributed.inlinePresentationIntent = .stronglyEmphasized
    switch style {
    case .find:
      let isCurrent = currentOffset == offset
      attributed.backgroundColor = isCurrent ? Color.yellow : Color.yellow.opacity(0.35)
      attributed.foregroundColor = isCurrent ? Color.black : Color.primary
    case .snippet:
      attributed.foregroundColor = .accentColor
    }
    return attributed
  }
}

extension View {
  /// Reports this site to find when it enters the hierarchy, and tags it as a scroll target.
  /// Both halves are needed: `.id` makes `scrollTo` able to reach it, `onAppear` tells find that a
  /// previously-absent site is now reachable.
  func findSite(_ anchor: FindAnchor, _ find: NodeFindState?) -> some View {
    self.id(anchor)
      .onAppear { find?.siteMounted(anchor) }
  }
}
