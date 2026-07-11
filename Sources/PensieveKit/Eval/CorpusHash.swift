// Sources/PensieveKit/Eval/CorpusHash.swift
import Foundation
import CryptoKit

public enum CorpusHash {
  public static func hash(_ parts: [Data]) -> String {
    var hasher = SHA256()
    for p in parts {
      var len = UInt64(p.count).littleEndian
      withUnsafeBytes(of: &len) { hasher.update(data: Data($0)) }  // length-prefix → order/boundary sensitive
      hasher.update(data: p)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

public struct CorpusManifest: Codable, Sendable {
  public var seed: UInt64
  public var contentHash: String
  public var counts: [String: Int]
  public var stressItems: [String]
  public init(seed: UInt64, contentHash: String, counts: [String: Int], stressItems: [String]) {
    self.seed = seed; self.contentHash = contentHash; self.counts = counts; self.stressItems = stressItems
  }
}
