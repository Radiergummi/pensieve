import Foundation

/// Trims and collapses every run of whitespace (incl. newlines) to a single space.
/// Used identically on both sides of the substring gate and for dedup.
public func normalizeWhitespace(_ string: String) -> String {
  string.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}
