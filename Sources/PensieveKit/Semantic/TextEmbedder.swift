import Foundation

public protocol TextEmbedder: Sendable {
  var version: String { get }     // e.g. "nl-latin:512" — derived from the loaded model at runtime
  var dimension: Int { get }
  /// One unit-normalized vector per input string, or nil if the model asset is unavailable.
  func embed(_ texts: [String]) async -> [[Float]]?
}

public enum EmbeddingMath {
  public static func meanPool(_ tokenVectors: [[Float]]) -> [Float] {
    guard let first = tokenVectors.first else { return [] }
    var acc = [Float](repeating: 0, count: first.count)
    for v in tokenVectors { for i in v.indices { acc[i] += v[i] } }
    let n = Float(tokenVectors.count)
    return acc.map { $0 / n }
  }
  public static func normalize(_ v: [Float]) -> [Float] {
    let mag = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    guard mag > 0 else { return v }
    return v.map { $0 / mag }
  }
  /// Cosine similarity of two unit vectors from a sqlite-vec L2 `distance`: for unit vectors,
  /// L2² = 2 - 2·cos, so cos = 1 - distance²/2.
  public static func cosine(fromL2 distance: Double) -> Double { 1.0 - (distance * distance) / 2.0 }
}
