import Foundation
import CoreSpotlight
import PensieveKit

/// Clear-then-index the active node set into Spotlight, restricted to the active Focus context's
/// visible nodes. Full re-index (nodes are few) keeps the index in exact sync. Read-only;
/// best-effort; never fatal.
enum SpotlightIndexer {
  static func reindex(activeContext: String = "") async {
    guard let database = try? openCanonicalDatabaseReadOnly(at: resolvedCanonicalURL()) else { return }
    let facts = (try? NodeFactsQueries.all(database, now: Date())) ?? []
    let allNodes = (try? ProjectQueries.all(database)) ?? []
    let visible = NodeContextResolver.visibleNodeIDs(for: activeContext, in: allNodes)
    let nodeEntities = facts.filter { visible.contains($0.node.id) }.map(NodeEntity.init(facts:))
    let looseEndEntities = ((try? LooseEndFactsQueries.all(database)) ?? [])
      .filter { visible.contains($0.nodeID) }
      .map(LooseEndEntity.init(facts:))
    let index = CSSearchableIndex.default()
    do {
      // Pensieve indexes only nodes + open loose ends → this clears exactly our set.
      try await index.deleteAllSearchableItems()
      try await index.indexAppEntities(nodeEntities)
      try await index.indexAppEntities(looseEndEntities)
    } catch {
      // A glance surface must never break the app; a failed index is silently dropped.
    }
  }
}
