import Foundation
import SQLiteData

/// Rebuilds the FTS5 search index from the live canonical corpus. Whole-rebuild, hash-guarded.
///
/// No per-item reconciliation: FTS5 insertion is cheap, so a full drop-and-reinsert is both simpler
/// and free of staleness bugs. (The retired vector indexer reconciled because embedding was the
/// expensive part — that trade-off left with it.) The guard exists
/// because the app calls this on every refresh that could have changed the corpus — launch, ⌘R, and
/// every debounced watch refresh, which includes the WAL changes the external daemon makes — and an
/// unchanged corpus should not churn the file.
///
/// Best-effort throughout: an unavailable store no-ops, a gather failure no-ops, and neither ever
/// blocks capture or ingest.
public struct SearchIndexer: Sendable {
  let store: SearchIndexStore
  public init(store: SearchIndexStore) { self.store = store }

  /// The indexer over the shared index for the store this process is pointed at. `SyncRunner`
  /// deliberately has no fallback to this — a test that constructed one would rebuild an index it
  /// never asked for — so every production entry point injects it explicitly.
  public static func production() -> SearchIndexer {
    SearchIndexer(store: SearchIndexStore(url: PensievePaths.searchIndexURL()))
  }

  public func sync(_ database: any DatabaseReader) {
    guard store.isAvailable else { return }
    guard let corpus = try? EmbeddableCorpus.gather(database) else { return }
    let hash = Self.corpusHash(corpus)
    // `.building` also forces a rebuild: the flag is committed in its own transaction before the
    // rebuild's, so a kill in that window leaves it latched with the corpus hash unchanged. Guarding
    // on the hash alone would then skip the rebuild forever, and every empty search would claim to
    // be "building" over an index that was actually fine.
    guard hash != store.storedCorpusHash() || store.state() == .building else { return }
    store.rebuild(items: corpus, corpusHash: hash)
  }

  /// FNV-1a over every field the index stores, sorted by (item id, language) so gather order cannot
  /// change the hash. `contentHash` covers `text`; `files` is folded in separately because
  /// `contentHash` deliberately excludes it (paths must never force a re-embed on the semantic side).
  ///
  /// The sort key is a PAIR, not just `itemID`: a translated document shares its original's item id,
  /// and Swift's sort is not stable, so sorting on the id alone would hash those two rows in
  /// arbitrary order. The rebuild guard compares this hash to the stored one, so a non-deterministic
  /// hash means a whole-corpus rebuild on every single sync.
  public static func corpusHash(_ items: [EmbeddableItem]) -> String {
    var hash = StableHash()
    for item in items.sorted(by: { ($0.itemID, $0.language) < ($1.itemID, $1.language) }) {
      hash.absorbField(item.itemID); hash.absorbField(item.contentHash)
      hash.absorbField(item.files); hash.absorbField(item.kind)
      hash.absorbField(item.nodeID); hash.absorbField(item.state)
      hash.absorbField(item.language)
    }
    return hash.hexValue
  }
}
