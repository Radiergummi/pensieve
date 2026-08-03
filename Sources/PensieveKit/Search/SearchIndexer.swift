import Foundation
import SQLiteData

/// Rebuilds the FTS5 search index from the live canonical corpus. Whole-rebuild, hash-guarded.
///
/// Unlike `SemanticIndexer` there is no reconciliation: embedding is expensive, FTS5 insertion is
/// not, so a full drop-and-reinsert is both simpler and free of staleness bugs. The guard exists
/// because the app calls this on every debounced refresh — that is every WAL change, including the
/// daemon's — and an unchanged corpus should not churn the file.
///
/// Best-effort throughout: an unavailable store no-ops, a gather failure no-ops, and neither ever
/// blocks capture or ingest.
public struct SearchIndexer: Sendable {
  let store: SearchIndexStore
  public init(store: SearchIndexStore) { self.store = store }

  public func sync(_ database: any DatabaseReader) {
    guard store.isAvailable else { return }
    guard let corpus = try? EmbeddableCorpus.gather(database) else { return }
    let hash = Self.corpusHash(corpus)
    guard hash != store.storedCorpusHash() else { return }
    store.rebuild(items: corpus, corpusHash: hash)
  }

  /// FNV-1a over every field the index stores, sorted by item id so gather order cannot change the
  /// hash. `contentHash` covers `text`; `files` is folded in separately because `contentHash`
  /// deliberately excludes it (paths must never force a re-embed on the semantic side).
  public static func corpusHash(_ items: [EmbeddableItem]) -> String {
    var accumulator: UInt64 = 1469598103934665603
    func absorb(_ text: String) {
      for byte in text.utf8 { accumulator = (accumulator ^ UInt64(byte)) &* 1099511628211 }
      accumulator = (accumulator ^ 0x1F) &* 1099511628211      // field separator
    }
    for item in items.sorted(by: { $0.itemID < $1.itemID }) {
      absorb(item.itemID); absorb(item.contentHash); absorb(item.files)
      absorb(item.kind); absorb(item.nodeID); absorb(item.state)
    }
    return String(accumulator, radix: 16)
  }
}
