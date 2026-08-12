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

/// The app's ONE highlight renderer: a `Text` concatenation over `FindRun`s, so there is no index
/// math and no full-string `AttributedString` round-trip. Defaults to the find style, since that is
/// the style every call site written for in-node find already assumes.
///
/// `Text.background(_:)` does not compile in a `Text + Text` chain (it resolves to the generic
/// `View.background(_:)`, which returns `ModifiedContent<Text, _>`, not `Text`). The `.find` tint is
/// applied instead via `AttributedString.backgroundColor` on just the matched run, wrapped back into
/// a `Text` (the `Text(AttributedString)` initializer returns `Text`, so it still concatenates).
struct HighlightedText: View {
  let runs: [FindRun]
  /// Character offset of the current match within this text, when it lives here. Ignored under
  /// `.snippet` style.
  var currentOffset: Int?
  var style: HighlightedTextStyle = .find

  var body: some View { composed }

  private var composed: Text {
    var pieces: [Text] = []
    var offset = 0
    for run in runs {
      switch run {
      case .plain(let text):
        pieces.append(Text(text))
      case .match(let text):
        pieces.append(matchText(text, offset: offset))
      }
      offset += run.text.count
    }
    return pieces.reduce(Text(""), +)
  }

  private func matchText(_ text: String, offset: Int) -> Text {
    switch style {
    case .find:
      let isCurrent = currentOffset == offset
      var attributed = AttributedString(text)
      attributed.backgroundColor = isCurrent ? Color.yellow : Color.yellow.opacity(0.35)
      return Text(attributed)
        .bold()
        .foregroundColor(isCurrent ? Color.black : Color.primary)
    case .snippet:
      return Text(text).bold().foregroundColor(.accentColor)
    }
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
