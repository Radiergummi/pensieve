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
  /// Which of the three legal query shapes this is. A sum type rather than a bag of optionals: the
  /// combinations those optionals could represent but this cannot (a path restriction AND an
  /// opportunistic path probe; no expression at all) are not shapes the store knows how to run, and
  /// the builder is the only thing entitled to decide which shape applies. The store switches
  /// exhaustively, so a fourth shape — a third table, say transcript passages — is a compile error
  /// there rather than a silently unhandled `if let`.
  public enum Shape: Equatable, Sendable {
    /// Bare terms, no explicit path directive: rank by text, then append rows only the path index
    /// could find. OR semantics — typing `SyncRunner.swift` must find the commits that touched it
    /// even though no commit message contains the string, so the same expression is tried against
    /// paths and its hits appended BELOW the text hits. Never ANDed, which would return nothing.
    case textWithPathProbe(String)
    /// An explicit path directive (`files:…`, or the structured `file:` parameter) with nothing to
    /// match in text: rank by path relevance alone.
    case pathOnly(String)
    /// Text AND an explicit path restriction. A join across the two tables, still ranked by TEXT
    /// relevance — the path narrows the candidate set and contributes no score.
    case textRestrictedByPath(text: String, path: String)
  }
  public let shape: Shape
  public let terms: [String]

  public init(shape: Shape, terms: [String]) { self.shape = shape; self.terms = terms }
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
    if let file, yieldsToken(file) {
      fileClauses.append(quoted(file))
      terms.append(file)
    }
    let text = textClauses.joined(separator: " AND ")
    let path = fileClauses.joined(separator: " AND ")
    // An explicit path directive restricts; without one, the bare terms are also tried against
    // paths so a filename typed on its own still finds the commits that touched it.
    let shape: FTSQuery.Shape
    switch (text.isEmpty, path.isEmpty) {
    case (false, true):  shape = .textWithPathProbe(text)
    case (true, false):  shape = .pathOnly(path)
    case (false, false): shape = .textRestrictedByPath(text: text, path: path)
    case (true, true):   return nil   // nothing survived — never run a pointless MATCH
    }
    return FTSQuery(shape: shape, terms: terms)
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
          if yieldsToken(phrase) { tokens.append(Token(text: phrase, isFileDirected: false)) }
          index = raw.index(after: close)
          endedOnClosedPhraseOrSpace = true
        } else {
          let phrase = String(raw[afterOpen...]).trimmingCharacters(in: .whitespaces)
          if yieldsToken(phrase) { tokens.append(Token(text: phrase, isFileDirected: false)) }
          index = raw.endIndex
        }
        continue
      }
      let wordEnd = raw[index...].firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" })
        ?? raw.endIndex
      let word = String(raw[index..<wordEnd])
      if word.lowercased().hasPrefix(filesPrefix) {
        let value = String(word.dropFirst(filesPrefix.count))
        if yieldsToken(value) { tokens.append(Token(text: value, isFileDirected: true)) }
      } else if yieldsToken(word) {
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

  /// Whether FTS5's `unicode61` tokenizer would produce at least one token for `text` — i.e. whether
  /// it contains anything from Unicode L* or N*, the only categories that tokenizer treats as token
  /// characters rather than separators.
  ///
  /// A word made only of separators (`—`, `-`, `->`, `|`, `/`, `+`, `...`) quotes into a legal but
  /// EMPTY phrase, and an empty phrase ANDed with real terms makes the WHOLE conjunction match
  /// nothing — so one punctuation word silently zeroes the result set while the index still reports
  /// `.ready`. That is not exotic input: `EmbeddableCorpus` joins a node as `name — description` and
  /// a loose end as `text — quote`, and the app renders those same strings, so copying a title out
  /// of the UI and pasting it into search returned zero hits for a document whose indexed text was
  /// character-for-character what was pasted. Ordinary typing hits it too (`client -> server`).
  ///
  /// Applied to quoted phrases as well, but that only ever drops a phrase that is ENTIRELY
  /// punctuation — which can never match any row, so ANDing it is guaranteed loss and never intent.
  /// `"Pensieve — search"` still yields tokens and is still searched as a phrase, which is why
  /// phrases could not simply be exempted wholesale.
  private static func yieldsToken(_ text: String) -> Bool {
    text.contains { $0.isLetter || $0.isNumber }
  }
}
