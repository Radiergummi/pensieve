// Sources/PensieveKit/Support/StableHash.swift
import Foundation

/// FNV-1a, accumulated incrementally. Stable across processes and runs, which is the whole point:
/// `String.hashValue` is per-process salted and must never back anything persisted or compared
/// between a stored value and a freshly computed one.
struct StableHash {
  private var accumulator: UInt64 = 1469598103934665603

  /// The raw bytes of `text`, with no delimiter — for a digest over a single value.
  mutating func absorb(_ text: String) {
    for byte in text.utf8 { absorb(byte) }
  }

  /// One field of a multi-field digest: the bytes plus a separator, so ("ab", "c") and ("a", "bc")
  /// cannot collide.
  mutating func absorbField(_ text: String) {
    absorb(text)
    absorb(0x1F)
  }

  private mutating func absorb(_ byte: UInt8) {
    accumulator = (accumulator ^ UInt64(byte)) &* 1099511628211
  }

  var hexValue: String { String(accumulator, radix: 16) }
}
