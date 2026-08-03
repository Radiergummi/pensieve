import Foundation
import GRDB
import SQLiteData

/// Best-effort derivation of a git-backed project node's `description` ("what it is") from local
/// repo signals. Outside the strict cited trust gate — like strand naming and narration. The unit
/// is shared by the daemon pass (`Ingester.describeProjectNodes`) and the app's manual refresh.
public enum NodeDescriber {
  /// What a single `describe` call did. `.wrote` is terminal (the node now has a description);
  /// `.attemptedEmpty` and `.noSignal` leave the description empty (retried on a later pass);
  /// `.ineligible` = not a single-git-source project, or already-described without `force`.
  public enum Outcome: Equatable, Sendable { case wrote, attemptedEmpty, noSignal, ineligible }

  /// The lone `gitRepo` source key for `nodeID`, or nil unless it has exactly one. Describe
  /// eligibility pairs this with a `project`-kind check on the node; shared so the daemon pass,
  /// the manual action, and the DetailView button gate resolve the git source identically.
  public static func soleGitRepoKey(_ database: Database, nodeID: UUID) throws -> String? {
    let git = try Source.where { $0.nodeID.eq(nodeID) && $0.kind.eq(SourceKind.gitRepo) }.fetchAll(database)
    return git.count == 1 ? git.first?.key : nil
  }

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

  /// Derive and write `nodeID`'s description. Eligible only for a `project` node with exactly one
  /// `gitRepo` source; `force` allows overwriting a non-empty description (the manual refresh) but
  /// never bypasses the single-git-source or meaningful-signal guards. Never throws — a provider
  /// failure or empty output is `.attemptedEmpty` (nothing written).
  public static func describe(_ database: any DatabaseWriter, nodeID: UUID,
                              provider: any LLMProvider, force: Bool) async -> Outcome {
    let resolved: (node: Node, key: String)? = (try? await database.read { database -> (Node, String)? in
      guard let node = try Node.where({ $0.id.eq(nodeID) }).fetchOne(database),
            node.kind == NodeKind.project,
            let key = try soleGitRepoKey(database, nodeID: nodeID) else { return nil }
      return (node, key)
    }) ?? nil
    guard let resolved else { return .ineligible }
    if !force, !resolved.node.description.isEmpty { return .ineligible }

    let ctx = ProjectContext.gather(commonDir: resolved.key)
    guard ProjectContext.hasMeaningfulSignal(ctx) else { return .noSignal }

    guard let raw = try? await provider.complete(prompt: ProjectContext.describePrompt(ctx)),
          let desc = sanitize(raw) else { return .attemptedEmpty }

    try? await database.write { database in
      try Node.where { $0.id.eq(nodeID) }.update { $0.description = desc }.execute(database)
    }
    return .wrote
  }
}
