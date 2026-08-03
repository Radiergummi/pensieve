import Foundation

/// A safe FTS5 `MATCH` expression plus the bare terms behind it (for snippet highlighting).
public struct FTSQuery: Equatable, Sendable {
  public let match: String
  public let terms: [String]
  public init(match: String, terms: [String]) { self.match = match; self.terms = terms }
}

/// Turns raw user input into an FTS5 `MATCH` expression. Pure — no I/O, no database.
///
/// FTS5 `MATCH` is a query language, so ordinary typing is hostile input: `don't`, `C++`, `a:b`,
/// an unbalanced `"`, and a lone `*` each throw a hard SQLite error when passed raw. Every term
/// therefore leaves here as a double-quoted FTS5 string literal (internal quotes doubled), which
/// disables all operator interpretation. Nothing else may build a MATCH expression.
public enum FTSQueryBuilder {
  private static let filesColumn = "files"
  private static let filesPrefix = "files:"

  public static func build(_ raw: String, file: String? = nil) -> FTSQuery? {
    var clauses: [String] = []
    var terms: [String] = []
    let parsed = parse(raw)

    for (index, token) in parsed.tokens.enumerated() {
      let isLast = index == parsed.tokens.count - 1
      // Prefix-match the final term as the user types, unless they finished the word with a space
      // or closed a quoted phrase, and never when a structured `file:` clause follows it.
      let prefixed = isLast && parsed.allowsTrailingPrefix && file == nil
      let literal = quoted(token.text) + (prefixed ? "*" : "")
      clauses.append(token.column == nil ? literal : "\(token.column!) : \(literal)")
      terms.append(token.text)
    }
    if let file, !file.trimmingCharacters(in: .whitespaces).isEmpty {
      clauses.append("\(filesColumn) : \(quoted(file))")
      terms.append(file)
    }
    guard !clauses.isEmpty else { return nil }
    return FTSQuery(match: clauses.joined(separator: " AND "), terms: terms)
  }

  private struct Token { let text: String; let column: String? }
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
          if !phrase.isEmpty { tokens.append(Token(text: phrase, column: nil)) }
          index = raw.index(after: close)
          endedOnClosedPhraseOrSpace = true
        } else {
          let phrase = String(raw[afterOpen...]).trimmingCharacters(in: .whitespaces)
          if !phrase.isEmpty { tokens.append(Token(text: phrase, column: nil)) }
          index = raw.endIndex
        }
        continue
      }
      let wordEnd = raw[index...].firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" })
        ?? raw.endIndex
      let word = String(raw[index..<wordEnd])
      if word.lowercased().hasPrefix(filesPrefix) {
        let value = String(word.dropFirst(filesPrefix.count))
        if !value.isEmpty { tokens.append(Token(text: value, column: filesColumn)) }
      } else if !word.isEmpty {
        tokens.append(Token(text: word, column: nil))
      }
      index = wordEnd
    }
    // A `files:` token is a column filter, not a word being typed — never prefix it.
    let lastIsColumnFiltered = tokens.last?.column != nil
    return Parsed(tokens: tokens,
                  allowsTrailingPrefix: !endedOnClosedPhraseOrSpace && !lastIsColumnFiltered)
  }

  /// An FTS5 string literal: wrap in double quotes, doubling any internal double quote.
  private static func quoted(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
