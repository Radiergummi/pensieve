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

  /// Normalizes a model's free-text description. One implementation, in `TextQuality` beside the
  /// label and recap gates — this used to be a second copy of that cleaning, and the copy lacked
  /// the structured-output reject, so a reject added for recaps never applied to descriptions.
  /// Brevity is left to the prompt (no sentence truncation — YAGNI, matching `narrate`).
  public static func sanitize(_ raw: String) -> String? {
    TextQuality.sanitizeDescription(raw)
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

    let context = ProjectContext.gather(commonDir: resolved.key)
    guard ProjectContext.hasMeaningfulSignal(context) else { return .noSignal }

    guard let raw = try? await provider.complete(prompt: ProjectContext.describePrompt(context)),
          let descriptionText = sanitize(raw) else { return .attemptedEmpty }

    // A failed write means the node still has no description, so say so: `.wrote` is terminal and
    // the caller logs it as a success, which is how a swallowed write error read as a described node.
    do {
      try await database.write { database in
        try Node.where { $0.id.eq(nodeID) }.update { $0.description = descriptionText }.execute(database)
      }
    } catch {
      Log.ingest.error("NodeDescriber write failed for \(nodeID, privacy: .public): \(error, privacy: .public)")
      return .attemptedEmpty
    }
    return .wrote
  }
}
