import Foundation

public enum TranscriptParser {
  public static func parse(fileURL: URL) -> ParsedSession {
    let iso = ISO8601DateFormatter()
    let sessionID = fileURL.deletingPathExtension().lastPathComponent
    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
      return ParsedSession(sessionID: sessionID, cwd: nil, startedAt: nil, endedAt: nil,
                           userPromptCount: 0, messages: [])
    }

    var cwd: String?
    var messages: [TranscriptMessage] = []
    var timestamps: [Date] = []
    var userPrompts = 0

    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }   // defensive: skip garbage lines

      if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
      if let ts = obj["timestamp"] as? String, let d = iso.date(from: ts) { timestamps.append(d) }

      let type = obj["type"] as? String
      let message = obj["message"] as? [String: Any]
      let role = (message?["role"] as? String) ?? (type ?? "unknown")
      let text = extractText(message?["content"])
      if type == "user" { userPrompts += 1 }
      if !text.isEmpty {
        messages.append(TranscriptMessage(role: role, text: text,
                                          timestamp: (obj["timestamp"] as? String).flatMap(iso.date(from:))))
      }
    }

    return ParsedSession(
      sessionID: sessionID, cwd: cwd,
      startedAt: timestamps.min(), endedAt: timestamps.max(),
      userPromptCount: userPrompts, messages: messages)
  }

  /// `content` is either a String or an array of content blocks (`{type:text,text:...}`).
  private static func extractText(_ content: Any?) -> String {
    if let s = content as? String { return s }
    if let blocks = content as? [[String: Any]] {
      return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    return ""
  }
}
