import Foundation

public enum TranscriptParser {
  public static func parse(fileURL: URL) -> ParsedSession {
    // Claude Code stamps fractional seconds ("…:43.382Z"); a default ISO8601DateFormatter
    // rejects those, so try the fractional format first and fall back to whole-second.
    let isoFractional = ISO8601DateFormatter()
    isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoPlain = ISO8601DateFormatter()
    func parseTimestamp(_ timestampString: String) -> Date? {
      isoFractional.date(from: timestampString) ?? isoPlain.date(from: timestampString)
    }
    let sessionID = fileURL.deletingPathExtension().lastPathComponent
    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
      // `wasReadable: false` is load-bearing, not decoration: it is the only signal that separates
      // "this file could not be read" from "this file had nothing to say", and the ingester retires
      // a session permanently on the second but not the first.
      return ParsedSession(sessionID: sessionID, cwd: nil, startedAt: nil, endedAt: nil,
                           userPromptCount: 0, messages: [], wasReadable: false)
    }

    var cwd: String?
    var messages: [TranscriptMessage] = []
    var timestamps: [Date] = []
    var userPrompts = 0
    var nextIndex = 0

    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let data = rawLine.data(using: .utf8),
            let line = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }   // defensive: skip garbage lines

      if cwd == nil, let cwdValue = line["cwd"] as? String { cwd = cwdValue }
      let timestamp = (line["timestamp"] as? String).flatMap(parseTimestamp)
      if let timestamp { timestamps.append(timestamp) }

      let type = line["type"] as? String
      let message = line["message"] as? [String: Any]
      let role = (message?["role"] as? String) ?? (type ?? "unknown")
      let content = message?["content"]
      let text = extractText(content)
      // Claude Code's own flag for injected/meta content (slash-command bodies, skill
      // bodies, caveats) that it records as `type:"user"` but isn't a human turn. This is
      // the robust primary gate; the marker list below is a backstop for inline-tagged
      // injections it doesn't flag (`<command-name>`, `<task-notification>`, …).
      let isMeta = (line["isMeta"] as? Bool) ?? false
      let isUserPrompt = (type == "user") && !isMeta && !isToolResult(content)
        && !isInjectedOrCommand(text) && !text.isEmpty
      // Count the SAME predicate the messages carry, not every `type:"user"` record. Claude Code
      // records each tool result as `type:"user"` too: measured on a real transcript, 331 of 362
      // such records were `tool_result`, so the old count rendered "session (207 prompts)" for
      // roughly 20 human turns. One definition of "a human turn", used for both the flag and the
      // count, is also what stops the two from drifting apart again.
      if isUserPrompt { userPrompts += 1 }
      if !text.isEmpty {
        messages.append(TranscriptMessage(index: nextIndex, role: role, text: text,
                                          timestamp: timestamp, isUserPrompt: isUserPrompt))
        nextIndex += 1
      }
    }

    return ParsedSession(
      sessionID: sessionID, cwd: cwd,
      startedAt: timestamps.min(), endedAt: timestamps.max(),
      userPromptCount: userPrompts, messages: messages)
  }

  /// `content` is either a String or an array of content blocks (`{type:text,text:...}`).
  private static func extractText(_ content: Any?) -> String {
    if let contentString = content as? String { return contentString }
    if let blocks = content as? [[String: Any]] {
      return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    return ""
  }

  /// True when a `type:"user"` record is actually a tool result, not human prose.
  private static func isToolResult(_ content: Any?) -> Bool {
    guard let blocks = content as? [[String: Any]] else { return false }
    return blocks.contains { ($0["type"] as? String) == "tool_result" }
  }

  /// True when `text` carries structural markers of a slash-command invocation, injected
  /// context, or a machine-authored envelope that Claude Code records as a `type:"user"`
  /// turn (subagent results, interruption notices, injected skill bodies) — none of which
  /// is genuine human prose. Skill bodies matter most: they are large and the extractor
  /// otherwise mines their embedded checklists/rubrics as fake loose ends.
  /// Markers are unambiguous tags no developer types by hand, so the risk of dropping real
  /// prose is nil. Semantic pasted briefs ("You are taking over…") have no reliable marker
  /// and are left to the IntentClassifier.
  private static func isInjectedOrCommand(_ text: String) -> Bool {
    TranscriptVocabulary.injectionMarkers.contains { text.contains($0) }
  }
}
