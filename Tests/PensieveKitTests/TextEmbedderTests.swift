import Testing
import Foundation
@testable import PensieveKit

@Suite struct TextEmbedderTests {
  @Test func meanPoolAveragesTokenVectors() {
    let pooled = EmbeddingMath.meanPool([[1, 0, 0], [0, 1, 0]])
    #expect(pooled == [0.5, 0.5, 0.0])
  }

  @Test func normalizeProducesUnitLength() {
    let normalized = EmbeddingMath.normalize([3, 4])   // |v| = 5
    #expect(abs((normalized[0] * normalized[0] + normalized[1] * normalized[1]) - 1.0) < 1e-6)
  }

  @Test func stubIsDeterministicAndUnit() async throws {
    let embedder = StubEmbedder(dimension: 8)
    let embeddingA = await embedder.embed(["hello"])
    let embeddingB = await embedder.embed(["hello"])
    #expect(embeddingA == embeddingB)
    let vector = try #require(embeddingA![0])
    #expect(abs(vector.reduce(0) { $0 + $1 * $1 } - 1.0) < 1e-6)   // unit length
  }

  @Test func cosineFromL2MapsIdenticalAndOrthogonal() {
    // L2 distance between identical unit vectors is 0 -> cosine similarity 1.
    #expect(abs(EmbeddingMath.cosine(fromL2: 0) - 1.0) < 1e-9)
    // L2 distance between orthogonal unit vectors is sqrt(2) -> cosine similarity 0.
    #expect(abs(EmbeddingMath.cosine(fromL2: 2.0.squareRoot()) - 0.0) < 1e-9)
  }
}
