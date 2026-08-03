// Sources/PensieveApp/AppModel+Recall.swift
import Foundation
import PensieveKit

extension AppModel {
  func detail(for node: Node) -> (status: ProjectStatus, looseEnds: [LooseEndView]) {
    let fallback = ProjectStatus(project: node, recentEvents: [])
    guard let database else { return (fallback, []) }
    let now = Date()
    let status = (try? ProjectQueries.status(database, node: node, limit: 15)) ?? fallback
    let ends = (try? LooseEndQueries.open(database, nodeID: node.id, now: now)) ?? []
    return (status, ends)
  }

  /// The node's recall rendered as shareable English Markdown. Reuses `detail(for:)` for the gather
  /// and includes the narration only if it's already cached (a share never blocks on an LLM call).
  func recallMarkdown(for node: Node) -> String {
    let detail = detail(for: node)
    // Respect the narration display toggle: a disabled recap must not leak into a share/export.
    let narration = AppDefaults.narrationEnabled ? cachedNarration(for: node, events: detail.status.recentEvents) : nil
    return RecallMarkdown.render(node: node, narration: narration,
                                 looseEnds: detail.looseEnds, events: detail.status.recentEvents, now: Date())
  }

  /// Open loose ends for a node — the inspector's slice of `detail(for:)` (no status query).
  /// Loaded once per selection via the inspector's `.task`, never in a view `body`.
  func looseEnds(forNode nodeID: UUID) -> [LooseEndView] {
    guard let database else { return [] }
    return (try? LooseEndQueries.open(database, nodeID: nodeID, now: Date())) ?? []
  }

  /// The cross-node audit queue for the Review Suggestions surface. Loaded off-`body` via `.task`.
  func reviewItems() -> [LooseEndView] {
    guard let database else { return [] }
    return (try? SalienceReviewQueries.pending(database, now: Date())) ?? []
  }

  /// Confirm a user salience label for a loose end (👍 salient / 👎 noise / "" clears).
  func setLooseEndLabel(_ looseEndID: UUID, _ label: String) {
    guard let database else { return }
    do {
      let succeeded = try LooseEndCommands.setLabel(database, id: looseEndID, label: label)
      if !succeeded { refuse(String(localized: "update"), String(localized: "this loose end")) }
    } catch {
      fail(String(localized: "update"), String(localized: "this loose end"), error)
    }
  }

  /// Surrounding-transcript provenance for a loose end, resolved off the main actor (file I/O).
  /// nil only when the source event is missing; a present-but-unavailable transcript returns a
  /// ProvenanceContext with `transcriptAvailable == false`.
  func provenance(for looseEnd: LooseEnd) async -> ProvenanceContext? {
    guard let database else { return nil }
    return try? await Task.detached { try ProvenanceQueries.context(database, looseEnd: looseEnd) }.value
  }
}
