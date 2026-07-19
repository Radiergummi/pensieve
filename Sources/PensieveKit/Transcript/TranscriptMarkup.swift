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
      // Tasks 4-5 insert callout / harness / placeholder / orphan-close handling here.
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
  /// line of an ordinary paragraph that merely happens to be indented is left as prose. Once
  /// opened, the block continues through further indented lines and absorbs blank lines only when
  /// another indented line follows — a trailing blank line before ordinary prose is left for the
  /// prose scan, so a tag on the line right after the block isn't swallowed into "code".
  mutating func consumeIndentedCodeLine() -> Bool {
    guard previousLineIsBlank else { return false }
    let (first, _) = line(at: i)
    guard first.hasPrefix("    ") else { return false }

    var cursor = i
    var end = i
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
}
