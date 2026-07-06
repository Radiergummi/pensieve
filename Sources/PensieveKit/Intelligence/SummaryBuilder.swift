import Foundation
import SQLiteData

public struct ProjectSummary: Sendable {
  public let whatItIs: String
  public let lastWorkDone: String
  public let looseEnds: [LooseEndView]
}

public struct SummaryBuilder: Sendable {
  private let provider: any LLMProvider
  public init(provider: any LLMProvider) { self.provider = provider }

  /// Deterministic fact sheet the model is allowed to narrate — and nothing beyond it.
  public static func assembleFacts(project: Node, events: [Event]) -> String {
    let lines = events.prefix(15).map { "- \($0.kind): \($0.summary)" }.joined(separator: "\n")
    return "Project: \(project.name)\nRecent activity:\n\(lines)"
  }

  /// The single constrained narration prompt — shared by `build` and `narrate` so the wording
  /// can't drift between them.
  private static func makePrompt(facts: String) -> String {
    """
    Narrate ONLY the facts below into 2-3 sentences of "last work done". Do NOT add any \
    fact, plan, or detail that is not explicitly present. If the facts are thin, say so.

    \(facts)
    """
  }

  public func build(_ db: any DatabaseWriter, node: Node, now: Date) async throws -> ProjectSummary? {
    // Key off the node the caller holds — NOT its name. Node names aren't unique (two distinct
    // repos can share a basename), so a name lookup would resolve an arbitrary same-named node
    // and, e.g., narrate an empty one while the real one's activity stays invisible.
    let status = try ProjectQueries.status(db, node: node, limit: 15)
    // Nothing captured for this node (e.g. a scanned-but-untouched git repo): skip it rather
    // than hand the model an empty fact sheet, which it "narrates" by hallucinating or echoing
    // the prompt. A loose end can't exist without a source event, so no events ⇒ nothing grounded.
    guard !status.recentEvents.isEmpty else { return nil }
    let facts = Self.assembleFacts(project: status.project, events: status.recentEvents)
    let narration = (try? await provider.complete(prompt: Self.makePrompt(facts: facts))) ?? facts   // fall back to raw facts
    let ends = try LooseEndQueries.open(db, nodeID: status.project.id, now: now)
    return ProjectSummary(
      whatItIs: "\(status.project.name) — \(status.project.state)",
      lastWorkDone: narration,
      looseEnds: ends)
  }

  /// Best-effort prose recap of the given events. Returns nil when there's nothing to narrate
  /// (no events) OR the provider fails/returns empty — never substitutes the raw fact sheet, so a
  /// caller can show a narration section only on a genuine result. Takes events directly (no DB
  /// re-query) so the prose narrates exactly what the caller already displays.
  public func narrate(project: Node, events: [Event]) async -> String? {
    guard !events.isEmpty else { return nil }
    let facts = Self.assembleFacts(project: project, events: events)
    guard let raw = try? await provider.complete(prompt: Self.makePrompt(facts: facts)) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
