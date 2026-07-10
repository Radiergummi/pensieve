// Sources/PensieveKit/Query/Snippet.swift
import Foundation

/// A search match split into three runs so a view can render the highlight with ZERO index
/// conversion: `Text(leading) + Text(match).bold() + Text(trailing)`. Sturdier and more testable
/// than a `Range<String.Index>`, and unicode-safe (all splits are on `String.Index`).
public struct Snippet: Equatable, Sendable {
  public var leading: String   // text before the match (may start with "…" when windowed)
  public var match: String     // the matched substring, original case ("" when no match)
  public var trailing: String  // text after the match (may end with "…" when windowed)
  public init(leading: String, match: String, trailing: String) {
    self.leading = leading; self.match = match; self.trailing = trailing
  }
}

public enum SnippetMaker {
  /// Case-insensitive first-occurrence match. Windows each side to `window` characters (adding an
  /// ellipsis when truncated), so `leading + match + trailing` always equals the shown text and
  /// `match` is exactly the matched substring. No match → a head window of the source in `leading`.
  public static func make(from source: String, matching query: String, window: Int = 80) -> Snippet {
    guard let r = source.range(of: query, options: .caseInsensitive) else {
      let head = String(source.prefix(window * 2))
      let lead = head.count < source.count ? head + "…" : head
      return Snippet(leading: lead, match: "", trailing: "")
    }
    let matched = String(source[r])
    var lead = String(source[source.startIndex..<r.lowerBound])
    if lead.count > window { lead = "…" + String(lead.suffix(window)) }
    var trail = String(source[r.upperBound...])
    if trail.count > window { trail = String(trail.prefix(window)) + "…" }
    return Snippet(leading: lead, match: matched, trailing: trail)
  }
}
