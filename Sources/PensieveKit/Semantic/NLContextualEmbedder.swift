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
    let latinEmbedding = NLContextualEmbedding(script: .latin)
    if let latinEmbedding, !latinEmbedding.hasAvailableAssets {
      // Kick off the async asset request; until it lands, embed() returns nil (best-effort).
      latinEmbedding.requestAssets { _, _ in }
    }
    self.model = latinEmbedding
    self.dimension = latinEmbedding?.dimension ?? 0
    self.version = "nl-latin:\(latinEmbedding?.dimension ?? 0)"
  }

  public func embed(_ texts: [String]) async -> [[Float]?]? {
    guard let model, model.hasAvailableAssets else { return nil }   // asset-level → whole batch nil
    do { try model.load() } catch { return nil }
    var out: [[Float]?] = []
    for text in texts {
      // Per-ITEM failure only. This model is Latin-script-only, so a non-Latin string is an
      // ordinary, expected outcome — it must not take its batch-mates down with it.
      guard let result = try? model.embeddingResult(for: text, language: nil) else {
        out.append(nil); continue
      }
      var tokens: [[Float]] = []
      result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
        tokens.append(vec.map { Float($0) }); return true
      }
      guard !tokens.isEmpty else { out.append(nil); continue }
      out.append(EmbeddingMath.normalize(EmbeddingMath.meanPool(tokens)))
    }
    return out
  }
}
