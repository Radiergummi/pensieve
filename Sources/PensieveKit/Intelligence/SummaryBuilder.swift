import Foundation
import SQLiteData

public struct ProjectSummary: Sendable {
  public let whatItIs: String
  public let lastWorkDone: String
  public let looseEnds: [LooseEndView]
}

public struct SummaryBuilder {
  private let provider: any LLMProvider
  public init(provider: any LLMProvider) { self.provider = provider }

  /// Deterministic fact sheet the model is allowed to narrate — and nothing beyond it.
  public static func assembleFacts(project: Project, events: [Event]) -> String {
    let lines = events.prefix(15).map { "- \($0.kind): \($0.summary)" }.joined(separator: "\n")
    return "Project: \(project.name)\nRecent activity:\n\(lines)"
  }

  public func build(_ db: any DatabaseWriter, projectName: String, now: Date) async throws -> ProjectSummary? {
    guard let status = try ProjectQueries.status(db, name: projectName, limit: 15) else { return nil }
    let facts = Self.assembleFacts(project: status.project, events: status.recentEvents)
    let prompt = """
    Narrate ONLY the facts below into 2-3 sentences of "last work done". Do NOT add any \
    fact, plan, or detail that is not explicitly present. If the facts are thin, say so.

    \(facts)
    """
    let narration = (try? await provider.complete(prompt: prompt)) ?? facts   // fall back to raw facts
    let ends = try LooseEndQueries.open(db, projectID: status.project.id, now: now)
    return ProjectSummary(
      whatItIs: "\(status.project.name) — \(status.project.state)",
      lastWorkDone: narration,
      looseEnds: ends)
  }
}
