import Testing
import Foundation
@testable import PensieveKit

@Suite struct SemanticIndexStoreTests {
  private func tempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("sem-\(UUID().uuidString).sqlite")
  }

  @Test func upsertThenKNNReturnsNearestWithMetadata() async {
    let store = SemanticIndexStore(url: tempURL(), dimension: 8, embedderVersion: "stub:8")
    #expect(store.isAvailable)
    let e = StubEmbedder(dimension: 8)
    let va = await e.embed(["alpha"])![0]
    let vb = await e.embed(["beta"])![0]
    store.upsert(row: .init(itemID: "a", kind: "loose_end", nodeID: "n1", state: "active",
                            contentHash: "h1"), embedding: va)
    store.upsert(row: .init(itemID: "b", kind: "loose_end", nodeID: "n2", state: "active",
                            contentHash: "h2"), embedding: vb)
    let hits = store.knn(query: va, k: 2, activeOnly: true)
    #expect(hits.first?.itemID == "a")
    #expect(hits.first?.nodeID == "n1")
    #expect(hits.first!.similarity > hits.last!.similarity)
  }

  @Test func activeOnlyFilterExcludesArchivedInKNN() async {
    let store = SemanticIndexStore(url: tempURL(), dimension: 8, embedderVersion: "stub:8")
    let e = StubEmbedder(dimension: 8)
    let v = await e.embed(["x"])![0]
    store.upsert(row: .init(itemID: "keep", kind: "node", nodeID: "n1", state: "active",
                            contentHash: "h"), embedding: v)
    store.upsert(row: .init(itemID: "gone", kind: "node", nodeID: "n2", state: "archived",
                            contentHash: "h"), embedding: v)
    let hits = store.knn(query: v, k: 5, activeOnly: true)
    #expect(hits.map(\.itemID) == ["keep"])
  }

  @Test func metadataOnlyUpsertUpdatesNodeWithoutEmbedding() async {
    let store = SemanticIndexStore(url: tempURL(), dimension: 8, embedderVersion: "stub:8")
    let e = StubEmbedder(dimension: 8)
    let v = await e.embed(["x"])![0]
    store.upsert(row: .init(itemID: "a", kind: "loose_end", nodeID: "old", state: "active",
                            contentHash: "h"), embedding: v)
    store.upsert(row: .init(itemID: "a", kind: "loose_end", nodeID: "new", state: "active",
                            contentHash: "h"), embedding: nil)   // repoint: node changes, no re-embed
    #expect(store.knn(query: v, k: 1, activeOnly: true).first?.nodeID == "new")
  }

  @Test func versionMismatchRebuildsEmpty() async {
    let url = tempURL()
    let e = StubEmbedder(dimension: 8)
    let v = await e.embed(["x"])![0]
    do {
      let s = SemanticIndexStore(url: url, dimension: 8, embedderVersion: "stub:8")
      s.upsert(row: .init(itemID: "a", kind: "node", nodeID: "n", state: "active",
                          contentHash: "h"), embedding: v)
    }
    let reopened = SemanticIndexStore(url: url, dimension: 8, embedderVersion: "stub:9")  // new version
    #expect(reopened.existingItems().isEmpty)   // dropped + rebuilt
  }

  @Test func existingItemsReturnsHashMap() async {
    let store = SemanticIndexStore(url: tempURL(), dimension: 8, embedderVersion: "stub:8")
    let e = StubEmbedder(dimension: 8)
    let v = await e.embed(["x"])![0]
    store.upsert(row: .init(itemID: "a", kind: "node", nodeID: "n", state: "active",
                            contentHash: "h1"), embedding: v)
    #expect(store.existingItems() == ["a": "h1"])
  }
}
