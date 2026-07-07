import Foundation
import CoreSpotlight
import PensieveKit

/// Clear-then-index the active node set into Spotlight, restricted to the active Focus context's
/// visible nodes. Full re-index (nodes are few) keeps the index in exact sync. Read-only;
/// best-effort; never fatal.
enum SpotlightIndexer {
  static func reindex(activeContext: String = "") async {
    guard let db = try? openCanonicalDatabaseReadOnly(at: Stores.canonicalURL) else { return }
    let facts = (try? NodeFactsQueries.all(db, now: Date())) ?? []
    let allNodes = (try? ProjectQueries.all(db)) ?? []
    let visible = NodeContextResolver.visibleNodeIDs(for: activeContext, in: allNodes)
    let entities = facts.filter { visible.contains($0.node.id) }.map(NodeEntity.init(facts:))
    let index = CSSearchableIndex.default()
    do {
      try await index.deleteAllSearchableItems()   // Pensieve indexes only nodes → this is exactly our set
      try await index.indexAppEntities(entities)
    } catch {
      // A glance surface must never break the app; a failed index is silently dropped.
    }
  }
}
