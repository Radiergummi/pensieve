import Testing
import Foundation
@testable import PensieveKit

@Suite struct TextEmbedderTests {
  @Test func meanPoolAveragesTokenVectors() {
    let pooled = EmbeddingMath.meanPool([[1, 0, 0], [0, 1, 0]])
    #expect(pooled == [0.5, 0.5, 0.0])
  }

  @Test func normalizeProducesUnitLength() {
    let n = EmbeddingMath.normalize([3, 4])   // |v| = 5
    #expect(abs((n[0] * n[0] + n[1] * n[1]) - 1.0) < 1e-6)
  }

  @Test func stubIsDeterministicAndUnit() async {
    let e = StubEmbedder(dimension: 8)
    let a = await e.embed(["hello"])
    let b = await e.embed(["hello"])
    #expect(a == b)
    let v = a![0]
    #expect(abs(v.reduce(0) { $0 + $1 * $1 } - 1.0) < 1e-6)   // unit length
  }

  @Test func cosineFromL2MapsIdenticalAndOrthogonal() {
    // L2 distance between identical unit vectors is 0 -> cosine similarity 1.
    #expect(abs(EmbeddingMath.cosine(fromL2: 0) - 1.0) < 1e-9)
    // L2 distance between orthogonal unit vectors is sqrt(2) -> cosine similarity 0.
    #expect(abs(EmbeddingMath.cosine(fromL2: 2.0.squareRoot()) - 0.0) < 1e-9)
  }
}
