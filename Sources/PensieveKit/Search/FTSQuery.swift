import Foundation

/// Safe FTS5 `MATCH` expressions plus the bare terms behind them (for snippet highlighting).
///
/// Text and file paths live in two separate FTS5 tables, so there are two expressions rather than
/// one. They are separate because a shared table measurably hurt ranking: FTS5 normalises bm25 by
/// the row's TOTAL token count across all columns, so carrying paths on commit rows discounted
/// their text matches against nodes and loose ends (P@1 0.395 → 0.378, McNemar p = 0.017, n = 1500).
/// A per-column weight bounds what a path MATCH contributes but does nothing about what a path's
/// mere PRESENCE costs; only separate tables fix that.
public struct FTSQuery: Equatable, Sendable {
  /// For the `documents` (text) table. Empty when the input was purely file-directed.
  public let match: String
  /// An explicit path restriction (`files:…`, or the structured `file:` parameter). AND semantics:
  /// the caller asked for work whose text matches AND whose paths match, so this joins to `match`
  /// rather than merging with it.
  public let filesFilter: String?
  /// An opportunistic path lookup built from the SAME bare terms as `match`, present only when the
  /// caller gave no explicit path directive. OR semantics: typing `syncrunner` should find commits
  /// that touched that file even though the word appears in no commit message, so its results are
  /// merged in below the text hits — never ANDed, which would return nothing.
  public let filesProbe: String?
  public let terms: [String]

  public init(match: String, filesFilter: String? = nil, filesProbe: String? = nil,
              terms: [String]) {
    self.match = match; self.filesFilter = filesFilter
    self.filesProbe = filesProbe; self.terms = terms
  }
}

/// Turns raw user input into an FTS5 `MATCH` expression. Pure — no I/O, no database.
///
/// FTS5 `MATCH` is a query language, so ordinary typing is hostile input: `don't`, `C++`, `a:b`,
/// an unbalanced `"`, and a lone `*` each throw a hard SQLite error when passed raw. Every term
/// therefore leaves here as a double-quoted FTS5 string literal (internal quotes doubled), which
/// disables all operator interpretation. Nothing else may build a MATCH expression.
public enum FTSQueryBuilder {
  private static let filesPrefix = "files:"

  public static func build(_ raw: String, file: String? = nil) -> FTSQuery? {
    var textClauses: [String] = []
    var fileClauses: [String] = []
    var terms: [String] = []
    let parsed = parse(raw)

    for (index, token) in parsed.tokens.enumerated() {
      let isLast = index == parsed.tokens.count - 1
      // Prefix-match the final term as the user types, unless they finished the word with a space
      // or closed a quoted phrase, and never when a structured `file:` clause follows it.
      let prefixed = isLast && parsed.allowsTrailingPrefix && file == nil
      let literal = quoted(token.text) + (prefixed ? "*" : "")
      if token.isFileDirected { fileClauses.append(literal) } else { textClauses.append(literal) }
      terms.append(token.text)
    }
    if let file, !file.trimmingCharacters(in: .whitespaces).isEmpty {
      fileClauses.append(quoted(file))
      terms.append(file)
    }
    guard !(textClauses.isEmpty && fileClauses.isEmpty) else { return nil }

    let match = textClauses.joined(separator: " AND ")
    // An explicit path directive restricts; without one, the bare terms are also tried against
    // paths so a filename typed on its own still finds the commits that touched it.
    let filesFilter = fileClauses.isEmpty ? nil : fileClauses.joined(separator: " AND ")
    let filesProbe = fileClauses.isEmpty && !match.isEmpty ? match : nil
    return FTSQuery(match: match, filesFilter: filesFilter, filesProbe: filesProbe, terms: terms)
  }

  private struct Token { let text: String; let isFileDirected: Bool }
  private struct Parsed { let tokens: [Token]; let allowsTrailingPrefix: Bool }

  private static func parse(_ raw: String) -> Parsed {
    var tokens: [Token] = []
    var index = raw.startIndex
    var endedOnClosedPhraseOrSpace = raw.isEmpty || raw.last == " "

    while index < raw.endIndex {
      let character = raw[index]
      if character == " " || character == "\t" || character == "\n" {
        index = raw.index(after: index)
        continue
      }
      if character == "\"" {
        // A balanced phrase ends at the next quote; an unbalanced one takes the rest of the input,
        // so a half-typed quote degrades into a phrase search instead of a SQLite error.
        let afterOpen = raw.index(after: index)
        if let close = raw[afterOpen...].firstIndex(of: "\"") {
          let phrase = String(raw[afterOpen..<close])
          if !phrase.isEmpty { tokens.append(Token(text: phrase, isFileDirected: false)) }
          index = raw.index(after: close)
          endedOnClosedPhraseOrSpace = true
        } else {
          let phrase = String(raw[afterOpen...]).trimmingCharacters(in: .whitespaces)
          if !phrase.isEmpty { tokens.append(Token(text: phrase, isFileDirected: false)) }
          index = raw.endIndex
        }
        continue
      }
      let wordEnd = raw[index...].firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" })
        ?? raw.endIndex
      let word = String(raw[index..<wordEnd])
      if word.lowercased().hasPrefix(filesPrefix) {
        let value = String(word.dropFirst(filesPrefix.count))
        if !value.isEmpty { tokens.append(Token(text: value, isFileDirected: true)) }
      } else if !word.isEmpty {
        tokens.append(Token(text: word, isFileDirected: false))
      }
      index = wordEnd
    }
    // A `files:` token is a column filter, not a word being typed — never prefix it.
    let lastIsColumnFiltered = tokens.last?.isFileDirected == true
    return Parsed(tokens: tokens,
                  allowsTrailingPrefix: !endedOnClosedPhraseOrSpace && !lastIsColumnFiltered)
  }

  /// An FTS5 string literal: wrap in double quotes, doubling any internal double quote.
  private static func quoted(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
