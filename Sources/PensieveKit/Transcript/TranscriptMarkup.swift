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

/// Parses `<NAME>` or `</NAME>` at a position: the bare name, whether it was a close tag, and the
/// index just past `>`.
struct TagMatch {
  let name: String
  let isClose: Bool
  let end: String.Index
}

/// The scan state. Prose accumulates into `pending` and is flushed as one `.markdown` segment
/// whenever a non-prose construct is emitted, so consecutive prose never fragments.
struct Scanner {
  let text: String
  var scanIndex: String.Index
  var out: [TranscriptSegment] = []
  var pending = ""

  init(_ text: String) {
    self.text = text
    self.scanIndex = text.startIndex
  }

  mutating func run() {
    while scanIndex < text.endIndex {
      if atLineStart, consumeFencedBlock() { continue }
      if atLineStart, consumeIndentedCodeLine() { continue }
      if text[scanIndex] == "`", consumeInlineCode() { continue }
      if consumeProseHarness() { continue }
      if text[scanIndex] == "<" {
        if consumeCallout() { continue }
        if consumeHarness() { continue }
        if consumePlaceholderOrOrphan() { continue }
      }
      pending.append(text[scanIndex])
      scanIndex = text.index(after: scanIndex)
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
    scanIndex == text.startIndex || text[text.index(before: scanIndex)] == "\n"
  }

  /// The line starting at `start`, excluding its newline, plus the index just past its newline.
  func line(at start: String.Index) -> (content: Substring, next: String.Index) {
    guard let newlineIndex = text[start...].firstIndex(of: "\n") else {
      return (text[start...], text.endIndex)
    }
    return (text[start..<newlineIndex], text.index(after: newlineIndex))
  }

  /// CommonMark fenced block, pinned: an opening fence is >=3 identical backticks or tildes with
  /// <=3 leading spaces; it closes only on >=N of the *same* character; an unterminated fence runs
  /// to end of message. Consumed verbatim into prose — never transformed (I3).
  mutating func consumeFencedBlock() -> Bool {
    let (first, afterFirst) = line(at: scanIndex)
    let indent = first.prefix { $0 == " " }
    guard indent.count <= 3 else { return false }
    let rest = first.dropFirst(indent.count)
    guard let fenceChar = rest.first, fenceChar == "`" || fenceChar == "~" else { return false }
    let openCount = rest.prefix { $0 == fenceChar }.count
    guard openCount >= 3 else { return false }

    pending += text[scanIndex..<afterFirst]
    var cursor = afterFirst
    while cursor < text.endIndex {
      let (lineContent, next) = line(at: cursor)
      pending += text[cursor..<next]
      cursor = next
      let strippedLine = lineContent.drop { $0 == " " }
      if strippedLine.prefix(while: { $0 == fenceChar }).count >= openCount,
         strippedLine.allSatisfy({ $0 == fenceChar || $0 == " " }) {
        break
      }
    }
    scanIndex = cursor
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
    let (first, firstNext) = line(at: scanIndex)
    guard first.hasPrefix("    "), !first.allSatisfy({ $0 == " " || $0 == "\t" }) else {
      return false
    }

    var cursor = firstNext
    var end = firstNext
    while cursor < text.endIndex {
      let (lineContent, next) = line(at: cursor)
      if lineContent.hasPrefix("    ") {
        cursor = next
        end = cursor
      } else if lineContent.allSatisfy({ $0 == " " || $0 == "\t" }) {
        cursor = next
      } else {
        break
      }
    }
    pending += text[scanIndex..<end]
    scanIndex = end
    return true
  }

  /// Whether the line immediately before `scanIndex` (which is at a line start) is blank — empty,
  /// whitespace-only, or simply absent because `scanIndex` is the start of the document.
  private var previousLineIsBlank: Bool {
    guard scanIndex > text.startIndex else { return true }
    let beforeNewline = text.index(before: scanIndex)          // the "\n" that put us at a line start
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
    let openCount = text[scanIndex...].prefix { $0 == "`" }.count
    let afterOpen = text.index(scanIndex, offsetBy: openCount)
    guard afterOpen < text.endIndex else { return false }

    var cursor = afterOpen
    while cursor < text.endIndex {
      guard let tick = text[cursor...].firstIndex(of: "`") else { return false }
      let runLength = text[tick...].prefix { $0 == "`" }.count
      if runLength == openCount {
        let end = text.index(tick, offsetBy: runLength)
        pending += text[scanIndex..<end]
        scanIndex = end
        return true
      }
      cursor = text.index(tick, offsetBy: runLength)
    }
    return false
  }

  /// Parses `<NAME>` or `</NAME>` at `start`. Returns nil for anything that isn't a well-formed
  /// simple tag.
  func tagName(at start: String.Index) -> TagMatch? {
    guard start < text.endIndex, text[start] == "<" else { return nil }
    var cursor = text.index(after: start)
    guard cursor < text.endIndex else { return nil }
    let isClose = text[cursor] == "/"
    if isClose { cursor = text.index(after: cursor) }
    guard let closeAngle = text[cursor...].firstIndex(of: ">") else { return nil }
    let name = String(text[cursor..<closeAngle])
    guard !name.isEmpty,
          name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    else { return nil }
    return TagMatch(name: name, isClose: isClose, end: text.index(after: closeAngle))
  }

  private func isAllCaps(_ name: String) -> Bool {
    name.contains { $0.isLetter } && !name.contains { $0.isLetter && $0.isLowercase }
  }

  /// Precedence 2: a paired ALL-CAPS tag, matched forward to the NEAREST matching close in the
  /// same message. The interior is emitted as markdown only — harness tags inside are not
  /// recursively parsed (I5).
  mutating func consumeCallout() -> Bool {
    guard let open = tagName(at: scanIndex), !open.isClose, isAllCaps(open.name) else { return false }
    guard let closeRange = text.range(of: "</\(open.name)>", range: open.end..<text.endIndex)
    else { return false }

    flushPending()
    let body = String(text[open.end..<closeRange.lowerBound])
    let raw = String(text[scanIndex..<closeRange.upperBound])
    out.append(.callout(.init(severity: .forTagName(open.name),
                              tagName: open.name, body: body, raw: raw)))
    scanIndex = closeRange.upperBound
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
    guard let tag = tagName(at: scanIndex) else { return false }
    guard tag.isClose || isAllCaps(tag.name) else {
      // A lowercase, unallowlisted open tag: escape so it stays visible, don't code-span it.
      pending += "\\<\(tag.name)\\>"
      scanIndex = tag.end
      return true
    }

    if suppressRewriteAtCurrentPosition {
      pending += "\\<\(tag.isClose ? "/" : "")\(tag.name)\\>"
    } else {
      pending += "`\(tag.isClose ? "/" : "")\(tag.name)`"
    }
    scanIndex = tag.end
    return true
  }

  private var suppressRewriteAtCurrentPosition: Bool {
    guard scanIndex > text.startIndex else { return false }
    let prev = text[text.index(before: scanIndex)]
    return prev.isLetter || prev.isNumber || prev == "_" || prev == "(" || prev == "["
  }
}

// MARK: - Harness blocks

extension Scanner {
  /// The modelled children of `<task-notification>`, recognised ONLY inside a matched span.
  private static let taskNotificationChildren = [
    "task-id", "tool-use-id", "output-file", "status", "summary", "note",
  ]

  /// Reads `<name>…</name>` starting at `from`, returning the body and the index past the close.
  private func element(_ name: String, from: String.Index) -> (body: String, end: String.Index)? {
    guard let open = tagName(at: from), !open.isClose, open.name == name else { return nil }
    guard let close = text.range(of: "</\(name)>", range: open.end..<text.endIndex) else { return nil }
    return (String(text[open.end..<close.lowerBound]), close.upperBound)
  }

  /// Precedence 3: an allowlisted harness tag, matched forward to its nearest close.
  mutating func consumeHarness() -> Bool {
    guard let open = tagName(at: scanIndex), !open.isClose,
          TranscriptVocabulary.harnessTagNames.contains(open.name),
          let close = text.range(of: "</\(open.name)>", range: open.end..<text.endIndex)
    else { return false }

    let body = String(text[open.end..<close.lowerBound])
    let resolved = harnessKind(forTag: open.name, body: body, afterClose: close.upperBound)

    flushPending()
    out.append(.harness(.init(kind: resolved.kind, raw: String(text[scanIndex..<resolved.end]))))
    scanIndex = resolved.end
    return true
  }

  /// Resolves the harness payload for an allowlisted tag already matched to its close, absorbing
  /// any adjacent modelled siblings (the command trio, `bash-input`'s stdout).
  private func harnessKind(forTag name: String, body: String, afterClose: String.Index) -> (kind: HarnessKind, end: String.Index) {
    switch name {
    case "command-name":
      return commandKind(name: body, afterClose: afterClose)
    case "command-message", "command-args":
      // Orphaned sibling (no preceding command-name): still a command block, name unknown.
      return (.command(name: "", message: name == "command-message" ? body : nil,
                       args: name == "command-args" ? body : nil), afterClose)
    case "task-notification":
      return (.taskNotification(Self.parseTaskNotification(body)), afterClose)
    case "bash-input":
      return bashIOKind(input: body, afterClose: afterClose)
    case "bash-stdout":
      return (.bashIO(input: nil, output: body), afterClose)
    default:
      return (simpleHarnessKind(forTag: name, body: body), afterClose)
    }
  }

  /// The command trio arrives adjacent; absorb the siblings that are actually present.
  private func commandKind(name: String, afterClose: String.Index) -> (kind: HarnessKind, end: String.Index) {
    var end = afterClose
    // `arguments` is the local; the `args:` label below is `HarnessKind.command`'s declared label and
    // the `"command-args"` string is Claude Code's wire tag — neither is renameable from here.
    var message: String?, arguments: String?
    if let commandMessage = element("command-message", from: end) { message = commandMessage.body; end = commandMessage.end }
    if let commandArgs = element("command-args", from: end) { arguments = commandArgs.body; end = commandArgs.end }
    return (.command(name: name, message: message, args: arguments), end)
  }

  private func bashIOKind(input: String, afterClose: String.Index) -> (kind: HarnessKind, end: String.Index) {
    var end = afterClose
    var output: String?
    if let stdoutElement = element("bash-stdout", from: end) { output = stdoutElement.body; end = stdoutElement.end }
    return (.bashIO(input: input, output: output), end)
  }

  /// The harness tags whose payload is a direct wrap of `body` with no sibling absorption.
  private func simpleHarnessKind(forTag name: String, body: String) -> HarnessKind {
    switch name {
    case "system-reminder":
      return .systemReminder(body)
    case "local-command-caveat":
      return .commandCaveat(body)
    case "local-command-stdout", "local-command-stderr":
      return .commandOutput(body)
    case "tool_uses":
      return .toolUses(body)
    case "tool_use_error":
      return .toolUseError(body)
    default:
      return .unknown(tag: name, body: body)
    }
  }

  /// Splits a task-notification's interior into modelled fields; anything else is preserved in
  /// `unrecognisedChildren` so nothing is silently dropped. Duplicate children (e.g. two
  /// `<status>`) are last-write-wins — not observed in practice, and harness output isn't expected
  /// to repeat a child tag.
  private static func parseTaskNotification(_ body: String) -> TaskNotificationBlock {
    var found: [String: String] = [:]
    var scanner = Scanner(body)
    while scanner.scanIndex < body.endIndex {
      if let tag = scanner.tagName(at: scanner.scanIndex), !tag.isClose,
         let close = body.range(of: "</\(tag.name)>", range: tag.end..<body.endIndex) {
        found[tag.name] = String(body[tag.end..<close.lowerBound])
        scanner.scanIndex = close.upperBound
      } else {
        scanner.scanIndex = body.index(after: scanner.scanIndex)
      }
    }
    var unrecognised = found
    for key in taskNotificationChildren { unrecognised.removeValue(forKey: key) }
    return TaskNotificationBlock(
      taskID: found["task-id"], toolUseID: found["tool-use-id"],
      outputFile: found["output-file"], status: found["status"],
      summary: found["summary"], note: found["note"],
      unrecognisedChildren: unrecognised)
  }

  /// The two harness kinds Claude Code emits as prose, not tags. `skillPreamble` is anchored to the
  /// start of the message with `hasPrefix` — a mid-message mention is someone talking about a
  /// skill, not the harness injecting one.
  mutating func consumeProseHarness() -> Bool {
    let skillMarker = "Base directory for this skill:"
    let caveatMarker =
      "Caveat: The messages below were generated by the user while running local commands"

    if scanIndex == text.startIndex, text.hasPrefix(skillMarker) {
      let (lineContent, next) = line(at: scanIndex)
      let path = lineContent.dropFirst(skillMarker.count).trimmingCharacters(in: .whitespaces)
      flushPending()
      out.append(.harness(.init(kind: .skillPreamble(path: path), raw: String(text[scanIndex..<next]))))
      scanIndex = next
      return true
    }

    if atLineStart, text[scanIndex...].hasPrefix(caveatMarker) {
      let (lineContent, next) = line(at: scanIndex)
      flushPending()
      out.append(.harness(.init(kind: .commandCaveat(String(lineContent)), raw: String(text[scanIndex..<next]))))
      scanIndex = next
      return true
    }

    if atLineStart, text[scanIndex...].hasPrefix("[Request interrupted") {
      let (_, next) = line(at: scanIndex)
      flushPending()
      out.append(.harness(.init(kind: .interrupted, raw: String(text[scanIndex..<next]))))
      scanIndex = next
      return true
    }

    return false
  }
}
