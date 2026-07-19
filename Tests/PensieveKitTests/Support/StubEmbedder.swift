import Foundation
@testable import PensieveKit

/// Deterministic embedder for tests: a stable per-string unit vector (hash-seeded), no assets.
struct StubEmbedder: TextEmbedder {
  let dimension: Int
  let version: String
  init(dimension: Int = 16, version: String = "stub:16") {
    self.dimension = dimension; self.version = version
  }
  func embed(_ texts: [String]) async -> [[Float]?]? {
    texts.map { text -> [Float]? in
      var seed = UInt64(bitPattern: Int64(text.hashValue))
      var v = [Float](repeating: 0, count: dimension)
      for i in 0..<dimension {                      // xorshift → deterministic pseudo-random
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        v[i] = Float(seed % 1000) / 1000.0 - 0.5
      }
      return EmbeddingMath.normalize(v)
    }
  }
}
