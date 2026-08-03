import Foundation

/// Drops candidate loose ends whose quote is not actually a loose end: a pure
/// closure/acknowledgement, a bare status-check, or a pasted checklist / tool-output
/// line. Pure and deterministic; runs after extraction, before the verbatim gate.
///
/// Recall-first by construction: a closure that PREFIXES a substantive directive or
/// question is KEPT ("yes, let's fix 2 and 3 too"), and there is NO truncation heuristic
/// (a legitimate mid-sentence quote like "still need to migrate the auth tables" starts
/// lowercase and must survive — truncation is fixed at its source in LooseEndExtractor).
/// See docs/superpowers/specs/2026-07-05-loose-end-noise-design.md.
public enum CandidateFilter {
  public static func strip(_ candidates: [LooseEndCandidate]) -> [LooseEndCandidate] {
    candidates.filter { !isNoise($0.quote) }
  }

  static func isNoise(_ quote: String) -> Bool {
    if isChecklistOrToolOutput(quote) { return true }
    let normalized = quote.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.isEmpty { return true }
    if isPureStatusCheck(normalized) { return true }
    if isPureClosure(normalized) { return true }
    return false
  }

  /// Completion / tool-output markers only. Deliberately EXCLUDES `- [ ]` / `- [x]`
  /// todo bullets: an unchecked box is a real open todo the user wants surfaced.
  static func isChecklistOrToolOutput(_ quote: String) -> Bool {
    let head = quote.trimmingCharacters(in: .whitespacesAndNewlines)
    let markers = ["✅", "❌", "☑", "+++", "@@", "```"]
    return markers.contains { head.hasPrefix($0) }
  }

  private static let closureTokens: Set<String> = [
    "looks good", "sounds good", "all good", "carry on", "go ahead",
    "approved", "perfect", "great", "nice", "thanks", "thank you",
    "yes", "yeah", "yep", "ok", "okay", "done", "lgtm",
  ]

  /// True iff EVERY clause (split on , ; . — ! ?) is itself a closure token. Any
  /// substantive clause → keep.
  static func isPureClosure(_ normalized: String) -> Bool {
    let clauses = normalized
      .split(whereSeparator: { ",;.—!?".contains($0) })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !clauses.isEmpty else { return false }
    return clauses.allSatisfy { closureTokens.contains($0) }
  }

  /// Whole-quote match against bare progress queries — never a prefix match (a status
  /// phrase followed by substantive content, e.g. "are you done with the auth refactor",
  /// must be KEPT).
  static func isPureStatusCheck(_ normalized: String) -> Bool {
    let core = normalized.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
    let patterns = [
      #"^are you done( yet)?$"#,
      #"^is it done( yet)?$"#,
      #"^did you finish( yet)?$"#,
      #"^are we ready( to \w+)?$"#,
      #"^what'?s the status$"#,
      #"^is .{1,40} still (running|going|open)$"#,
    ]
    return patterns.contains { core.range(of: $0, options: .regularExpression) != nil }
  }
}
