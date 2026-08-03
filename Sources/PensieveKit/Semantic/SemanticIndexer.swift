import Foundation
import SQLiteData

/// Incremental reconciliation of the semantic index against the live canonical corpus.
/// Membership- and metadata-driven, NOT hash-driven: pruning follows corpus membership (so a
/// closed/noise loose end disappears even though its text never changed; an archived node's
/// items stay, with their `state` flipped instead). For an UNCHANGED item, metadata (node_id/state)
/// is upserted unconditionally (so a
/// repoint updates the index without re-embedding). A NEW or content-CHANGED item is only
/// upserted once it has been (re-)embedded this run — if the embedder can't produce a vector,
/// it's skipped entirely and retried on the next sync(). Best-effort: no-ops when the index is
/// unavailable or the embedder can't produce vectors this run.
public struct SemanticIndexer: Sendable {
  let store: SemanticIndexStore
  let embedder: any TextEmbedder
  public init(store: SemanticIndexStore, embedder: any TextEmbedder) {
    self.store = store; self.embedder = embedder
  }

  public func sync(_ database: any DatabaseReader) async {
    guard store.isAvailable else { return }
    guard let corpus = try? EmbeddableCorpus.gather(database) else { return }
    let existing = store.existingItems()                 // item_id -> content_hash
    let liveIDs = Set(corpus.map { $0.itemID })

    // Prune anything no longer in the live corpus (closed/noise loose ends, deleted). Archived
    // items stay live (their `state` metadata is upserted below, not pruned).
    let stale = existing.keys.filter { !liveIDs.contains($0) }
    store.delete(itemIDs: Array(stale))

    // Which items need (re-)embedding: new, or content_hash changed.
    let needEmbed = corpus.filter { existing[$0.itemID] != $0.contentHash }
    var vectors: [String: [Float]] = [:]
    if !needEmbed.isEmpty, let embedded = await embedder.embed(needEmbed.map { truncate($0.text) }) {
      // Per-item nil = that string failed; skip it (stays absent → retried next sync) and keep
      // every successfully embedded batch-mate.
      for (item, vec) in zip(needEmbed, embedded) { vectors[item.itemID] = vec }
    }
    // Upsert every live item: metadata always; vector only when (re-)embedded this run.
    // Items that needed embedding but didn't get a vector (embedder returned nil / partial
    // result) are skipped entirely so they stay absent/stale in existingItems() and are
    // retried on the next sync() — never permanently starved of their first-ever embedding
    // or left with a silently stale one.
    for item in corpus {
      let unchanged = existing[item.itemID] == item.contentHash
      guard unchanged || vectors[item.itemID] != nil else { continue }
      store.upsert(row: .init(itemID: item.itemID, kind: item.kind, nodeID: item.nodeID,
                              state: item.state, contentHash: item.contentHash),
                   embedding: vectors[item.itemID])
    }
  }

  // v1: truncate to a safe character budget for the BERT-class token window. Real chunking rides
  // in with transcripts (a future EmbeddableItem producer).
  private func truncate(_ text: String) -> String { String(text.prefix(2000)) }
}
