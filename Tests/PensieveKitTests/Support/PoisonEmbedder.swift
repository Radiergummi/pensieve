import Foundation
@testable import PensieveKit

/// Embedder that fails exactly the items whose text contains `poison`, and succeeds on the rest —
/// simulating the real `NLContextualEmbedder` behaviour where one string fails tokenization (e.g.
/// non-Latin script, zero tokens) while its batch-mates are perfectly embeddable.
struct PoisonEmbedder: TextEmbedder {
  let dimension: Int
  let version: String
  let poison: String
  init(dimension: Int = 16, version: String = "stub:16", poison: String) {
    self.dimension = dimension; self.version = version; self.poison = poison
  }
  func embed(_ texts: [String]) async -> [[Float]?]? {
    let good = StubEmbedder(dimension: dimension, version: version)
    var out: [[Float]?] = []
    for text in texts {
      if text.contains(poison) { out.append(nil); continue }
      out.append(await good.embed([text])?.first ?? nil)
    }
    return out
  }
}
