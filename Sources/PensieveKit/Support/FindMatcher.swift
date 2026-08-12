// Sources/PensieveKit/Support/FindMatcher.swift
import Foundation

/// One rendering run of a searched string: either untouched text or a matched span. Generalizes
/// `Snippet`'s three-run trick from one match to N, so a view renders `Text` concatenations with
/// ZERO index conversion — the same reason `Snippet` exists.
public enum FindRun: Equatable, Sendable {
  case plain(String)
  case match(String)

  /// The run's text, whichever case it is.
  public var text: String {
    switch self {
    case .plain(let text), .match(let text): return text
    }
  }
}

/// Literal substring matching for in-node find — Safari semantics: no regex, no whole-word, no
/// stemming.
public enum FindMatcher {
  /// **The single definition of how Pensieve compares a query to captured text.** `SnippetMaker`
  /// reads this rather than declaring its own copy: `Snippet.swift` already carries a scar comment
  /// about two paths disagreeing on these options, and a fourth copy would invite the same bug.
  ///
  /// Diacritic folding matches the retrieval engine — the FTS5 index is built with
  /// `remove_diacritics 2`, so typing `losung` genuinely retrieves `Lösung`; comparing case-only
  /// here would hand back a real hit that the view then renders with nothing highlighted.
  public static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

  /// The FIRST occurrence of `query` in `source`, or nil. Same comparison as `ranges` — callers that
  /// need one match (a search snippet) go through here rather than building every range and taking
  /// `.first`, which scans the whole string for nothing.
  public static func firstRange(in source: String, query: String) -> Range<String.Index>? {
    guard !query.isEmpty, !source.isEmpty else { return nil }
    return source.range(of: query, options: options)
  }

  /// Every occurrence of `query` in `source`, left to right, non-overlapping. Unicode-safe: all
  /// bounds are `String.Index`. Note a matched range may differ in length from `query` — diacritic
  /// folding compares `Lösung` equal to `losung`.
  public static func ranges(in source: String, query: String) -> [Range<String.Index>] {
    guard !query.isEmpty, !source.isEmpty else { return [] }
    var found: [Range<String.Index>] = []
    var searchStart = source.startIndex
    while searchStart < source.endIndex,
          let range = source.range(of: query, options: options,
                                   range: searchStart..<source.endIndex) {
      found.append(range)
      // A zero-width match would spin forever; advance one character in that (defensive) case.
      searchStart = range.upperBound > range.lowerBound
        ? range.upperBound
        : source.index(after: range.lowerBound)
    }
    return found
  }

  /// Splits `source` into alternating plain/match runs. Invariant: joining every run's text
  /// reproduces `source` exactly — the property the round-trip test pins.
  public static func runs(in source: String, ranges: [Range<String.Index>]) -> [FindRun] {
    guard !ranges.isEmpty else { return source.isEmpty ? [] : [.plain(source)] }
    var runs: [FindRun] = []
    var cursor = source.startIndex
    for range in ranges {
      if cursor < range.lowerBound {
        runs.append(.plain(String(source[cursor..<range.lowerBound])))
      }
      runs.append(.match(String(source[range])))
      cursor = range.upperBound
    }
    if cursor < source.endIndex {
      runs.append(.plain(String(source[cursor...])))
    }
    return runs
  }
}
