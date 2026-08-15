import AppIntents
import SQLiteData
import PensieveKit

/// Resolves LooseEndEntities for Spotlight/Shortcuts/Siri. Opens the canonical store READ-ONLY and
/// degrades to empty if it's missing — an intent surface must never create/migrate the store.
struct LooseEndEntityQuery: EntityQuery, EntityStringQuery {
  /// A tap / by-id resolution — any status/state, so a since-closed end still opens its node.
  func entities(for identifiers: [UUID]) async throws -> [LooseEndEntity] {
    read { try LooseEndFactsQueries.facts(for: identifiers, $0) }.map(LooseEndEntity.init(facts:))
  }

  /// The Shortcuts parameter picker — open loose ends in active nodes.
  func suggestedEntities() async throws -> [LooseEndEntity] {
    read { try LooseEndFactsQueries.all($0) }.map(LooseEndEntity.init(facts:))
  }

  /// Text/quote search (case-insensitive). Loose ends are few/single-user, so filter in Swift.
  func entities(matching string: String) async throws -> [LooseEndEntity] {
    read { try LooseEndFactsQueries.all($0) }
      .filter {
        $0.text.localizedCaseInsensitiveContains(string)
          || $0.quote.localizedCaseInsensitiveContains(string)
      }
      .map(LooseEndEntity.init(facts:))
  }

  private func read(_ body: (any DatabaseReader) throws -> [LooseEndFacts]) -> [LooseEndFacts] {
    guard let database = try? openCanonicalDatabaseReadOnly(at: resolvedCanonicalURL()) else { return [] }
    return (try? body(database)) ?? []
  }
}
