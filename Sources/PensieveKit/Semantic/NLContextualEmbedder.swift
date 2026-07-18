import Foundation
import NaturalLanguage

/// On-device sentence embeddings via NLContextualEmbedding (by-script Latin, covers EN+DE).
/// Per-token model → mean-pooled + unit-normalized to one vector per string. Best-effort:
/// returns nil until the model asset is loaded (never throws, never blocks capture/ingest).
public final class NLContextualEmbedder: TextEmbedder, @unchecked Sendable {
  private let model: NLContextualEmbedding?
  public let dimension: Int
  public let version: String

  public init() {
    let m = NLContextualEmbedding(script: .latin)
    if let m, !m.hasAvailableAssets {
      // Kick off the async asset request; until it lands, embed() returns nil (best-effort).
      m.requestAssets { _, _ in }
    }
    self.model = m
    self.dimension = m?.dimension ?? 0
    self.version = "nl-latin:\(m?.dimension ?? 0)"
  }

  public func embed(_ texts: [String]) async -> [[Float]]? {
    guard let model, model.hasAvailableAssets else { return nil }
    do { try model.load() } catch { return nil }
    var out: [[Float]] = []
    for text in texts {
      guard let result = try? model.embeddingResult(for: text, language: nil) else { return nil }
      var tokens: [[Float]] = []
      result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
        tokens.append(vec.map { Float($0) }); return true
      }
      guard !tokens.isEmpty else { return nil }
      out.append(EmbeddingMath.normalize(EmbeddingMath.meanPool(tokens)))
    }
    return out
  }
}
