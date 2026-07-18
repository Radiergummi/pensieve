import Foundation
import SQLiteData

/// Incremental reconciliation of the semantic index against the live canonical corpus.
/// Membership- and metadata-driven, NOT hash-driven: pruning follows corpus membership (so a
/// closed/noise loose end or an archived node's items disappear even though their text never
/// changed), metadata (node_id/state) is upserted for every live item unconditionally (so a
/// repoint updates the index without re-embedding), and (re-)embedding happens only for new
/// items or ones whose content_hash changed. Best-effort: no-ops when the index is unavailable
/// or the embedder can't produce vectors this run.
public struct SemanticIndexer: Sendable {
  let store: SemanticIndexStore
  let embedder: any TextEmbedder
  public init(store: SemanticIndexStore, embedder: any TextEmbedder) {
    self.store = store; self.embedder = embedder
  }

  public func sync(_ db: any DatabaseReader) async {
    guard store.isAvailable else { return }
    guard let corpus = try? EmbeddableCorpus.gather(db) else { return }
    let existing = store.existingItems()                 // item_id -> content_hash
    let liveIDs = Set(corpus.map { $0.itemID })

    // Prune anything no longer in the live corpus (closed/noise loose ends, archived, deleted).
    let stale = existing.keys.filter { !liveIDs.contains($0) }
    store.delete(itemIDs: Array(stale))

    // Which items need (re-)embedding: new, or content_hash changed.
    let needEmbed = corpus.filter { existing[$0.itemID] != $0.contentHash }
    var vectors: [String: [Float]] = [:]
    if !needEmbed.isEmpty, let embedded = await embedder.embed(needEmbed.map { truncate($0.text) }) {
      for (item, vec) in zip(needEmbed, embedded) { vectors[item.itemID] = vec }
    }
    // Upsert every live item: metadata always; vector only when (re-)embedded this run.
    for item in corpus {
      store.upsert(row: .init(itemID: item.itemID, kind: item.kind, nodeID: item.nodeID,
                              state: item.state, contentHash: item.contentHash),
                   embedding: vectors[item.itemID])
    }
  }

  // v1: truncate to a safe character budget for the BERT-class token window. Real chunking rides
  // in with transcripts (a future EmbeddableItem producer).
  private func truncate(_ s: String) -> String { String(s.prefix(2000)) }
}
