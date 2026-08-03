import Foundation

public protocol TextEmbedder: Sendable {
  var version: String { get }     // e.g. "nl-latin:512" — derived from the loaded model at runtime
  var dimension: Int { get }
  /// One entry per input string, positionally aligned with `texts`.
  ///
  /// Two levels of nil, deliberately distinct:
  /// - outer nil — the model asset is unavailable; nothing could be embedded this run.
  /// - inner nil — THAT string could not be embedded (tokenization failed / produced no tokens),
  ///   while its batch-mates succeeded. One bad string must never sink the whole batch: the
  ///   indexer feeds the entire pending set in one call, and an all-or-nothing failure would
  ///   block every other pending item indefinitely (a failed item never records its hash, so it
  ///   rejoins the next batch and fails it again).
  func embed(_ texts: [String]) async -> [[Float]?]?
}

public enum EmbeddingMath {
  public static func meanPool(_ tokenVectors: [[Float]]) -> [Float] {
    guard let first = tokenVectors.first else { return [] }
    var acc = [Float](repeating: 0, count: first.count)
    for tokenVector in tokenVectors { for index in tokenVector.indices { acc[index] += tokenVector[index] } }
    let vectorCount = Float(tokenVectors.count)
    return acc.map { $0 / vectorCount }
  }
  public static func normalize(_ vector: [Float]) -> [Float] {
    let mag = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    guard mag > 0 else { return vector }
    return vector.map { $0 / mag }
  }
  /// Cosine similarity of two unit vectors from a sqlite-vec L2 `distance`: for unit vectors,
  /// L2² = 2 - 2·cos, so cos = 1 - distance²/2.
  public static func cosine(fromL2 distance: Double) -> Double { 1.0 - (distance * distance) / 2.0 }
}
