import AppIntents
import SQLiteData
import PensieveKit

/// Resolves NodeEntities for Spotlight/Shortcuts/Siri. Opens the canonical store READ-ONLY and
/// degrades to empty if it's missing — an intent surface must never create/migrate the store.
struct NodeEntityQuery: EntityQuery, EntityStringQuery {
  /// A tap / by-id resolution — any state, so a since-archived node still opens. Unknown id → dropped.
  func entities(for identifiers: [UUID]) async throws -> [NodeEntity] {
    read { try NodeFactsQueries.facts(for: identifiers, $0, now: Date()) }.map(NodeEntity.init(facts:))
  }

  /// The Shortcuts parameter picker — active nodes.
  func suggestedEntities() async throws -> [NodeEntity] {
    read { try NodeFactsQueries.all($0, now: Date()) }.map(NodeEntity.init(facts:))
  }

  /// Name search (case-insensitive). Nodes are few, so filter in Swift — no fragile LIKE predicate.
  func entities(matching string: String) async throws -> [NodeEntity] {
    read { try NodeFactsQueries.all($0, now: Date()) }
      .filter { $0.node.name.localizedCaseInsensitiveContains(string) }
      .map(NodeEntity.init(facts:))
  }

  private func read(_ body: (any DatabaseReader) throws -> [NodeFacts]) -> [NodeFacts] {
    guard let database = try? openCanonicalDatabaseReadOnly(at: Stores.canonicalURL) else { return [] }
    return (try? body(database)) ?? []
  }
}
