import Foundation
@testable import PensieveKit

/// Embedder that always fails: simulates the model asset not yet downloaded, or a transient
/// embedding failure. Used to prove SemanticIndexer's best-effort no-op/retry behavior.
struct NilEmbedder: TextEmbedder {
  let dimension: Int
  let version: String
  init(dimension: Int = 16, version: String = "stub:16") {
    self.dimension = dimension; self.version = version
  }
  func embed(_ texts: [String]) async -> [[Float]?]? { nil }
}
