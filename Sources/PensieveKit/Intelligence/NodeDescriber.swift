import Foundation
import SQLiteData

/// Best-effort derivation of a git-backed project node's `description` ("what it is") from local
/// repo signals. Outside the strict cited trust gate — like strand naming and narration. The unit
/// is shared by the daemon pass (`Ingester.describeProjectNodes`) and the app's manual refresh.
public enum NodeDescriber {
  /// What a single `describe` call did. `.wrote` is terminal (the node now has a description);
  /// `.attemptedEmpty` and `.noSignal` leave the description empty (retried on a later pass);
  /// `.ineligible` = not a single-git-source project, or already-described without `force`.
  public enum Outcome: Equatable, Sendable { case wrote, attemptedEmpty, noSignal, ineligible }

  /// Normalizes a model's free-text description: trims; strips surrounding code fences; strips a
  /// leading list/heading marker; strips surrounding quotes. Returns nil when nothing is left.
  /// Brevity is left to the prompt (no sentence truncation — YAGNI, matching `narrate`).
  public static func sanitize(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("```") {
      s = s.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let marker = s.range(of: #"^(\d+[.)]|[-*•#]+)\s+"#, options: .regularExpression) {
      s.removeSubrange(marker)
    }
    s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
  }
}
