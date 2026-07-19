import Testing
import Foundation
@testable import PensieveKit

@Suite struct SemanticIndexStoreTests {
  private func tempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("sem-\(UUID().uuidString).sqlite")
  }

  private func store() -> SemanticIndexStore {
    SemanticIndexStore(url: tempURL(), dimension: 16, embedderVersion: "stub:16")
  }

  @Test func upsertThenKNNReturnsNearestWithMetadata() async {
    let store = SemanticIndexStore(url: tempURL(), dimension: 8, embedderVersion: "stub:8")
    #expect(store.isAvailable)
    let e = StubEmbedder(dimension: 8)
    let va = await e.embed(["alpha"])![0]!
    let vb = await e.embed(["beta"])![0]!
    store.upsert(row: .init(itemID: "a", kind: "loose_end", nodeID: "n1", state: "active",
                            contentHash: "h1"), embedding: va)
    store.upsert(row: .init(itemID: "b", kind: "loose_end", nodeID: "n2", state: "active",
                            contentHash: "h2"), embedding: vb)
    let hits = store.knn(query: va, k: 2, includeArchived: false)
    #expect(hits.first?.itemID == "a")
    #expect(hits.first?.nodeID == "n1")
    #expect(hits.first!.similarity > hits.last!.similarity)
  }

  @Test func activeOnlyFilterExcludesArchivedInKNN() async {
    let store = SemanticIndexStore(url: tempURL(), dimension: 8, embedderVersion: "stub:8")
    let e = StubEmbedder(dimension: 8)
    let v = await e.embed(["x"])![0]!
    store.upsert(row: .init(itemID: "keep", kind: "node", nodeID: "n1", state: "active",
                            contentHash: "h"), embedding: v)
    store.upsert(row: .init(itemID: "gone", kind: "node", nodeID: "n2", state: "archived",
                            contentHash: "h"), embedding: v)
    let hits = store.knn(query: v, k: 5, includeArchived: false)
    #expect(hits.map(\.itemID) == ["keep"])
  }

  @Test func metadataOnlyUpsertUpdatesNodeWithoutEmbedding() async {
    let store = SemanticIndexStore(url: tempURL(), dimension: 8, embedderVersion: "stub:8")
    let e = StubEmbedder(dimension: 8)
    let v = await e.embed(["x"])![0]!
    store.upsert(row: .init(itemID: "a", kind: "loose_end", nodeID: "old", state: "active",
                            contentHash: "h"), embedding: v)
    store.upsert(row: .init(itemID: "a", kind: "loose_end", nodeID: "new", state: "active",
                            contentHash: "h"), embedding: nil)   // repoint: node changes, no re-embed
    #expect(store.knn(query: v, k: 1, includeArchived: false).first?.nodeID == "new")
  }

  @Test func versionMismatchRebuildsEmpty() async {
    let url = tempURL()
    let e = StubEmbedder(dimension: 8)
    let v = await e.embed(["x"])![0]!
    do {
      let s = SemanticIndexStore(url: url, dimension: 8, embedderVersion: "stub:8")
      s.upsert(row: .init(itemID: "a", kind: "node", nodeID: "n", state: "active",
                          contentHash: "h"), embedding: v)
    }
    let reopened = SemanticIndexStore(url: url, dimension: 8, embedderVersion: "stub:9")  // new version
    #expect(reopened.existingItems().isEmpty)   // dropped + rebuilt
  }

  @Test func sameVersionReopenPreservesData() async {
    let url = tempURL()
    let e = StubEmbedder(dimension: 8)
    let v = await e.embed(["x"])![0]!
    do {
      let s = SemanticIndexStore(url: url, dimension: 8, embedderVersion: "stub:8")
      s.upsert(row: .init(itemID: "a", kind: "node", nodeID: "n", state: "active",
                          contentHash: "h"), embedding: v)
    }
    // Reopen with the SAME version + dimension → must NOT drop; indexed data survives.
    let reopened = SemanticIndexStore(url: url, dimension: 8, embedderVersion: "stub:8")
    #expect(reopened.existingItems() == ["a": "h"])
    #expect(reopened.knn(query: v, k: 1, includeArchived: false).first?.itemID == "a")
  }

  @Test func existingItemsReturnsHashMap() async {
    let store = SemanticIndexStore(url: tempURL(), dimension: 8, embedderVersion: "stub:8")
    let e = StubEmbedder(dimension: 8)
    let v = await e.embed(["x"])![0]!
    store.upsert(row: .init(itemID: "a", kind: "node", nodeID: "n", state: "active",
                            contentHash: "h1"), embedding: v)
    #expect(store.existingItems() == ["a": "h1"])
  }

  @Test func knnExcludesArchivedByDefaultAndIncludesItWhenAsked() async throws {
    let s = store()
    let embedder = StubEmbedder(dimension: 16)
    guard let vecs = await embedder.embed(["active work", "archived work", "muted work"]),
          let activeVec = vecs[0], let archivedVec = vecs[1], let mutedVec = vecs[2] else {
      Issue.record("stub embedder returned no vectors"); return
    }
    s.upsert(row: .init(itemID: "a", kind: "node", nodeID: "n1",
                        state: NodeState.active.rawValue, contentHash: "h1"), embedding: activeVec)
    s.upsert(row: .init(itemID: "b", kind: "node", nodeID: "n2",
                        state: NodeState.archived.rawValue, contentHash: "h2"), embedding: archivedVec)
    s.upsert(row: .init(itemID: "c", kind: "node", nodeID: "n3",
                        state: NodeState.muted.rawValue, contentHash: "h3"), embedding: mutedVec)

    let narrow = Set(s.knn(query: activeVec, k: 10, includeArchived: false).map { $0.itemID })
    #expect(narrow == ["a"])

    let wide = Set(s.knn(query: activeVec, k: 10, includeArchived: true).map { $0.itemID })
    #expect(wide == ["a", "b"])            // archived in, muted still out
    #expect(!wide.contains("c"))
  }

  @Test func archiveFlipIsMetadataOnlyAndPreservesTheVector() async throws {
    let s = store()
    let embedder = StubEmbedder(dimension: 16)
    guard let vecs = await embedder.embed(["legacy billing"]), let vec = vecs[0] else {
      Issue.record("stub embedder returned no vectors"); return
    }
    // Indexed while active, with a vector.
    s.upsert(row: .init(itemID: "x", kind: "node", nodeID: "n1",
                        state: NodeState.active.rawValue, contentHash: "h"), embedding: vec)
    // The node is archived: same content hash, so the indexer upserts metadata with NO embedding.
    s.upsert(row: .init(itemID: "x", kind: "node", nodeID: "n1",
                        state: NodeState.archived.rawValue, contentHash: "h"), embedding: nil)

    // The vector survived the flip: the row is still KNN-reachable, now under the wide filter.
    #expect(s.knn(query: vec, k: 10, includeArchived: false).isEmpty)
    #expect(s.knn(query: vec, k: 10, includeArchived: true).map { $0.itemID } == ["x"])

    // And it flips back symmetrically, still without ever being re-embedded.
    s.upsert(row: .init(itemID: "x", kind: "node", nodeID: "n1",
                        state: NodeState.active.rawValue, contentHash: "h"), embedding: nil)
    #expect(s.knn(query: vec, k: 10, includeArchived: false).map { $0.itemID } == ["x"])
  }
}
