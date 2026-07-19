import Foundation

/// Splits one transcript message into rendering segments.
///
/// **A single left-to-right scan in which the outermost construct wins.** A multi-pass pipeline
/// (harness first, then callouts) is self-contradictory: a callout containing a `<system-reminder>`
/// gets split into two unpaired fragments, both demoted to raw text, and the callout vanishes.
///
/// Precedence at each position: code → callout → harness → placeholder → orphan close → prose.
/// Tasks 4 and 5 add the middle four; this file starts with code and prose.
public enum TranscriptMarkup {
  public static func parse(_ input: String) -> [TranscriptSegment] {
    var scanner = Scanner(input)
    scanner.run()
    return scanner.out
  }
}

/// The scan state. Prose accumulates into `pending` and is flushed as one `.markdown` segment
/// whenever a non-prose construct is emitted, so consecutive prose never fragments.
struct Scanner {
  let text: String
  var i: String.Index
  var out: [TranscriptSegment] = []
  var pending = ""

  init(_ text: String) {
    self.text = text
    self.i = text.startIndex
  }

  mutating func run() {
    while i < text.endIndex {
      if atLineStart, consumeFencedBlock() { continue }
      if atLineStart, consumeIndentedCodeLine() { continue }
      if text[i] == "`", consumeInlineCode() { continue }
      if text[i] == "<" {
        if consumeCallout() { continue }
        // Task 5 inserts `if consumeHarness() { continue }` here.
        if consumePlaceholderOrOrphan() { continue }
      }
      pending.append(text[i])
      i = text.index(after: i)
    }
    flushPending()
  }

  /// Emits accumulated prose as one segment. No-op when empty, so we never emit `.markdown("")`.
  mutating func flushPending() {
    guard !pending.isEmpty else { return }
    out.append(.markdown(pending))
    pending = ""
  }

  var atLineStart: Bool {
    i == text.startIndex || text[text.index(before: i)] == "\n"
  }

  /// The line starting at `start`, excluding its newline, plus the index just past its newline.
  func line(at start: String.Index) -> (content: Substring, next: String.Index) {
    guard let nl = text[start...].firstIndex(of: "\n") else {
      return (text[start...], text.endIndex)
    }
    return (text[start..<nl], text.index(after: nl))
  }

  /// CommonMark fenced block, pinned: an opening fence is >=3 identical backticks or tildes with
  /// <=3 leading spaces; it closes only on >=N of the *same* character; an unterminated fence runs
  /// to end of message. Consumed verbatim into prose — never transformed (I3).
  mutating func consumeFencedBlock() -> Bool {
    let (first, afterFirst) = line(at: i)
    let indent = first.prefix { $0 == " " }
    guard indent.count <= 3 else { return false }
    let rest = first.dropFirst(indent.count)
    guard let fenceChar = rest.first, fenceChar == "`" || fenceChar == "~" else { return false }
    let openCount = rest.prefix { $0 == fenceChar }.count
    guard openCount >= 3 else { return false }

    pending += text[i..<afterFirst]
    var cursor = afterFirst
    while cursor < text.endIndex {
      let (l, next) = line(at: cursor)
      pending += text[cursor..<next]
      cursor = next
      let li = l.drop { $0 == " " }
      if li.prefix(while: { $0 == fenceChar }).count >= openCount,
         li.allSatisfy({ $0 == fenceChar || $0 == " " }) {
        break
      }
    }
    i = cursor
    return true
  }

  /// A run of one or more 4-space-indented lines, started only when the line before it is blank or
  /// absent — i.e. it can actually *open* an indented code block, per CommonMark; a continuation
  /// line of an ordinary paragraph that merely happens to be indented is left as prose. A line that
  /// is itself blank (only spaces/tabs, even ones satisfying the 4-space prefix) cannot open a
  /// block either — CommonMark treats blank lines as separators, not content. Once opened, the
  /// block continues through further indented lines and absorbs blank lines only when another
  /// indented line follows — a trailing blank line before ordinary prose is left for the prose
  /// scan, so a tag on the line right after the block isn't swallowed into "code".
  mutating func consumeIndentedCodeLine() -> Bool {
    guard previousLineIsBlank else { return false }
    let (first, firstNext) = line(at: i)
    guard first.hasPrefix("    "), !first.allSatisfy({ $0 == " " || $0 == "\t" }) else {
      return false
    }

    var cursor = firstNext
    var end = firstNext
    while cursor < text.endIndex {
      let (l, next) = line(at: cursor)
      if l.hasPrefix("    ") {
        cursor = next
        end = cursor
      } else if l.allSatisfy({ $0 == " " || $0 == "\t" }) {
        cursor = next
      } else {
        break
      }
    }
    pending += text[i..<end]
    i = end
    return true
  }

  /// Whether the line immediately before `i` (which is at a line start) is blank — empty,
  /// whitespace-only, or simply absent because `i` is the start of the document.
  private var previousLineIsBlank: Bool {
    guard i > text.startIndex else { return true }
    let beforeNewline = text.index(before: i)          // the "\n" that put us at a line start
    guard beforeNewline > text.startIndex else { return true }
    var cursor = text.index(before: beforeNewline)
    var sawContent = false
    while true {
      if text[cursor] == "\n" { break }
      if text[cursor] != " " && text[cursor] != "\t" { sawContent = true; break }
      if cursor == text.startIndex { break }
      cursor = text.index(before: cursor)
    }
    return !sawContent
  }

  /// An inline code span: N backticks closed by exactly N backticks. Pairs left-to-right; an
  /// unbalanced trailing backtick protects nothing and is emitted as ordinary prose.
  mutating func consumeInlineCode() -> Bool {
    let openCount = text[i...].prefix { $0 == "`" }.count
    let afterOpen = text.index(i, offsetBy: openCount)
    guard afterOpen < text.endIndex else { return false }

    var cursor = afterOpen
    while cursor < text.endIndex {
      guard let tick = text[cursor...].firstIndex(of: "`") else { return false }
      let runLength = text[tick...].prefix { $0 == "`" }.count
      if runLength == openCount {
        let end = text.index(tick, offsetBy: runLength)
        pending += text[i..<end]
        i = end
        return true
      }
      cursor = text.index(tick, offsetBy: runLength)
    }
    return false
  }

  /// Parses `<NAME>` or `</NAME>` at `start`. Returns the bare name, whether it was a close tag,
  /// and the index just past `>`. Returns nil for anything that isn't a well-formed simple tag.
  func tagName(at start: String.Index) -> (name: String, isClose: Bool, end: String.Index)? {
    guard start < text.endIndex, text[start] == "<" else { return nil }
    var cursor = text.index(after: start)
    guard cursor < text.endIndex else { return nil }
    let isClose = text[cursor] == "/"
    if isClose { cursor = text.index(after: cursor) }
    guard let gt = text[cursor...].firstIndex(of: ">") else { return nil }
    let name = String(text[cursor..<gt])
    guard !name.isEmpty,
          name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    else { return nil }
    return (name, isClose, text.index(after: gt))
  }

  private func isAllCaps(_ name: String) -> Bool {
    name.contains { $0.isLetter } && !name.contains { $0.isLetter && $0.isLowercase }
  }

  /// Precedence 2: a paired ALL-CAPS tag, matched forward to the NEAREST matching close in the
  /// same message. The interior is emitted as markdown only — harness tags inside are not
  /// recursively parsed (I5).
  mutating func consumeCallout() -> Bool {
    guard let open = tagName(at: i), !open.isClose, isAllCaps(open.name) else { return false }
    guard let closeRange = text.range(of: "</\(open.name)>", range: open.end..<text.endIndex)
    else { return false }

    flushPending()
    let body = String(text[open.end..<closeRange.lowerBound])
    let raw = String(text[i..<closeRange.upperBound])
    out.append(.callout(.init(severity: .forTagName(open.name),
                              tagName: open.name, body: body, raw: raw)))
    i = closeRange.upperBound
    return true
  }

  /// Precedence 4 and 5: an unmatched ALL-CAPS open, or ANY orphan close, becomes an inert
  /// monospace run. Backward pairing is forbidden — an orphan close pairing with a distant earlier
  /// open would swallow unrelated content, which is exactly what I4 exists to prevent.
  ///
  /// The rewrite is suppressed when the preceding character is an identifier char, `(`, or `[`,
  /// which kills two real hazards in one predicate: Swift generics in prose (`Optional<NSError>`)
  /// and link destinations (`[docs](<PROJECT>/readme)`). Suppressed tags are backslash-escaped
  /// rather than left bare, because bare `<NSError>` is valid CommonMark raw HTML that MarkdownUI
  /// would swallow — losing the text is worse than the bug being fixed.
  mutating func consumePlaceholderOrOrphan() -> Bool {
    guard let tag = tagName(at: i) else { return false }
    guard tag.isClose || isAllCaps(tag.name) else {
      // A lowercase, unallowlisted open tag: escape so it stays visible, don't code-span it.
      pending += "\\<\(tag.name)\\>"
      i = tag.end
      return true
    }

    if suppressRewriteAtCurrentPosition {
      pending += "\\<\(tag.isClose ? "/" : "")\(tag.name)\\>"
    } else {
      pending += "`\(tag.isClose ? "/" : "")\(tag.name)`"
    }
    i = tag.end
    return true
  }

  private var suppressRewriteAtCurrentPosition: Bool {
    guard i > text.startIndex else { return false }
    let prev = text[text.index(before: i)]
    return prev.isLetter || prev.isNumber || prev == "_" || prev == "(" || prev == "["
  }
}
