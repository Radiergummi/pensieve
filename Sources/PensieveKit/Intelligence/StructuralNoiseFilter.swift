import Foundation

/// Drops long, template-structured agent briefs / review-packages from the set of user
/// prompts BEFORE loose-end mining. Pure and deterministic. Deliberately never touches
/// SHORT messages: in a coding-agent session a terse imperative ("You are absolutely
/// right, fix X") IS the developer's genuine intent, so brief detection is gated on
/// length AND template structure — not on conversational openers. Checklists are handled
/// at the candidate level (see CandidateFilter), not here, so a real ask wrapped around a
/// checklist survives. See docs/superpowers/specs/2026-07-05-loose-end-noise-design.md.
public enum StructuralNoiseFilter {
  /// A message must be at least this long to even be considered a brief. No terse human
  /// directive reaches this; generated briefs are multi-paragraph.
  static let minBriefLength = 800

  public static func strip(_ messages: [TranscriptMessage]) -> [TranscriptMessage] {
    messages.filter { !isBrief($0.text) }
  }

  /// A brief needs the length AND enough template signals — but "enough" depends on whether the
  /// message opens like a generated brief, because the two weakest signals co-occur in ordinary
  /// human writing. A long design brief the developer types himself routinely contains a
  /// meta-instruction ("Do not touch the schema") and two bold labels ("**Goal:**", "**Scope:**"),
  /// and at two signals flat that was classified as harness noise and dropped before mining — the
  /// single message most likely to *contain* loose ends. So: an opener (the one signal no human
  /// message produces by accident — `hasOpener` matches only this project's own brief preambles,
  /// and only as a prefix) buys the old threshold; without one, the message must show three of the
  /// four signals before we call it generated.
  static func isBrief(_ text: String) -> Bool {
    guard text.count >= minBriefLength else { return false }
    let signals = templateSignals(in: text)
    return hasOpener(text) ? signals >= 2 : signals >= 3
  }

  /// Distinct generated-brief signals present in `text` (max 4).
  static func templateSignals(in text: String) -> Int {
    var signalCount = 0
    if hasOpener(text) { signalCount += 1 }
    if hasMetaInstruction(text) { signalCount += 1 }
    if text.range(of: #"Task \d+"#, options: .regularExpression) != nil { signalCount += 1 }
    if sectionHeaderCount(text) >= 2 { signalCount += 1 }
    return signalCount
  }

  private static let openers = [
    "You are implementing", "You are reviewing", "You are RE-reviewing",
    "You are dispatched", "High-scrutiny",
  ]
  static func hasOpener(_ text: String) -> Bool {
    let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return openers.contains { head.hasPrefix($0) }
  }

  private static let metaPhrases = [
    "Return ONLY", "Do not ", "Acceptance criteria", "Deliverable:",
    "Your job is", "task-brief", "review-package",
  ]
  static func hasMetaInstruction(_ text: String) -> Bool {
    metaPhrases.contains { text.contains($0) }
  }

  /// Markdown section headers: a line starting with 1-6 `#` + space, or a bold label
  /// line like `**Foo:**`.
  static func sectionHeaderCount(_ text: String) -> Int {
    text.split(separator: "\n").reduce(0) { accumulated, line in
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)
      let heading = trimmedLine.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil
        || trimmedLine.range(of: #"^\*\*.+:\*\*"#, options: .regularExpression) != nil
      return accumulated + (heading ? 1 : 0)
    }
  }
}
