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
  let translations: TranslationStore?
  let language: String
  public init(store: SearchIndexStore, translations: TranslationStore? = nil,
              language: String = TranslationTarget.off) {
    self.store = store
    self.translations = translations
    self.language = language
  }

  /// The indexer over the shared index for the store this process is pointed at. `SyncRunner`
  /// deliberately has no fallback to this — a test that constructed one would rebuild an index it
  /// never asked for — so every production entry point injects it explicitly.
  public static func production() -> SearchIndexer {
    let language = TranslationTarget.resolved()
    // Off means off: do not even open the translation store, so no file is created.
    let translations = language.isEmpty ? nil
      : TranslationStore(url: PensievePaths.translationCacheURL())
    return SearchIndexer(store: SearchIndexStore(url: PensievePaths.searchIndexURL()),
                         translations: translations, language: language)
  }

  public func sync(_ database: any DatabaseReader) {
    guard store.isAvailable else { return }
    guard let corpus = try? EmbeddableCorpus.gather(database, translations: translations,
                                                   language: language) else { return }
    let hash = Self.corpusHash(corpus)
    // `.building` also forces a rebuild: the flag is committed in its own transaction before the
    // rebuild's, so a kill in that window leaves it latched with the corpus hash unchanged. Guarding
    // on the hash alone would then skip the rebuild forever, and every empty search would claim to
    // be "building" over an index that was actually fine.
    guard hash != store.storedCorpusHash() || store.state() == .building else { return }
    store.rebuild(items: corpus, corpusHash: hash)
  }

  /// Rebuilds the passage index when its own corpus moved. Separate from `sync` and guarded on its
  /// own hash: passages change only when a session is ingested, while nodes/loose ends/events change
  /// on every commit, so sharing one hash would rebuild ~50k passage documents for a one-line commit.
  ///
  /// Reuses `corpusHash` — the passage items carry the same fields, and `files`/`language`/`status`
  /// are constant across them, so the hash is still a faithful digest of what the table holds.
  public func syncPassages(_ database: any DatabaseReader) {
    guard store.isAvailable else { return }
    guard let corpus = try? EmbeddableCorpus.gatherPassages(database) else { return }
    let hash = Self.corpusHash(corpus)
    guard hash != store.storedPassagesHash() else { return }
    store.rebuildPassages(items: corpus, passagesHash: hash)
  }

  /// FNV-1a over every field the index stores, sorted by (item id, language) so gather order cannot
  /// change the hash. `contentHash` covers `text`; `files` is folded in separately because
  /// `contentHash` deliberately excludes it (paths must never force a re-embed on the semantic side).
  ///
  /// The sort key is a PAIR, not just `itemID`: a translated document shares its original's item id,
  /// and Swift's sort is not stable, so sorting on the id alone would hash those two rows in
  /// arbitrary order. The rebuild guard compares this hash to the stored one, so a non-deterministic
  /// hash means a whole-corpus rebuild on every single sync.
  ///
  /// `status` is folded in because closing a loose end changes NOTHING else about its document — the
  /// text, id, kind, node and language are all identical. Omit it and the guard skips the rebuild,
  /// leaving the index calling a closed end open, so it keeps surfacing in the default scope forever.
  public static func corpusHash(_ items: [EmbeddableItem]) -> String {
    var hash = StableHash()
    for item in items.sorted(by: { ($0.itemID, $0.language) < ($1.itemID, $1.language) }) {
      hash.absorbField(item.itemID); hash.absorbField(item.contentHash)
      hash.absorbField(item.files); hash.absorbField(item.kind)
      hash.absorbField(item.nodeID); hash.absorbField(item.state)
      hash.absorbField(item.language); hash.absorbField(item.status)
    }
    return hash.hexValue
  }
}
