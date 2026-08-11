// Sources/PensieveApp/HighlightedText.swift
import SwiftUI
import PensieveKit

/// The app's ONE highlight renderer: a `Text` concatenation over `FindRun`s, so there is no index
/// math and no full-string `AttributedString` round-trip. All matches tint; the current match tints
/// strongly — Safari's convention.
///
/// `Text.background(_:)` does not compile in a `Text + Text` chain (it resolves to the generic
/// `View.background(_:)`, which returns `ModifiedContent<Text, _>`, not `Text`). The tint is applied
/// instead via `AttributedString.backgroundColor` on just the matched run, wrapped back into a
/// `Text` (the `Text(AttributedString)` initializer returns `Text`, so it still concatenates).
struct HighlightedText: View {
  let runs: [FindRun]
  /// Character offset of the current match within this text, when it lives here.
  var currentOffset: Int?

  var body: some View { composed }

  private var composed: Text {
    var pieces: [Text] = []
    var offset = 0
    for run in runs {
      switch run {
      case .plain(let text):
        pieces.append(Text(text))
      case .match(let text):
        let isCurrent = currentOffset == offset
        var attributed = AttributedString(text)
        attributed.backgroundColor = isCurrent ? Color.yellow : Color.yellow.opacity(0.35)
        pieces.append(Text(attributed)
          .bold()
          .foregroundColor(isCurrent ? Color.black : Color.primary))
      }
      offset += run.text.count
    }
    return pieces.reduce(Text(""), +)
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
