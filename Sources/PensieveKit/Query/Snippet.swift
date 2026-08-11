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
    guard let matchRange = source.range(of: query, options: .caseInsensitive) else {
      let head = String(source.prefix(window * 2))
      let lead = head.count < source.count ? head + "…" : head
      return Snippet(leading: lead, match: "", trailing: "")
    }
    let matched = String(source[matchRange])
    var lead = String(source[source.startIndex..<matchRange.lowerBound])
    if lead.count > window { lead = "…" + String(lead.suffix(window)) }
    var trail = String(source[matchRange.upperBound...])
    if trail.count > window { trail = String(trail.prefix(window)) + "…" }
    return Snippet(leading: lead, match: matched, trailing: trail)
  }

  /// Highlights the first of `terms` that occurs in `source`, scanning terms in order. BM25 is
  /// unstemmed, so a matched region is always a query term or a word it prefixes — substring
  /// highlighting stays correct without parsing FTS5's own `snippet()` marker string, and the
  /// displayed text keeps coming from the canonical store rather than the index.
  public static func make(from source: String, matchingAny terms: [String],
                          window: Int = 80) -> Snippet {
    // Keep the first term that actually produced a highlight. Testing for a match first and then
    // re-running the search would search twice per term AND let the two searches disagree on their
    // options — a term found under one comparison and missed by the other yielded no highlight.
    for term in terms where !term.isEmpty {
      let snippet = make(from: source, matching: term, window: window)
      if !snippet.match.isEmpty { return snippet }
    }
    return make(from: source, matching: "", window: window)
  }
}
