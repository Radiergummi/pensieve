// Tests/PensieveKitTests/CorpusHashTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Test func hashIsStableAndOrderSensitive() {
  let a = Data("one".utf8), b = Data("two".utf8)
  #expect(CorpusHash.hash([a, b]) == CorpusHash.hash([a, b]))
  #expect(CorpusHash.hash([a, b]) != CorpusHash.hash([b, a]))
  #expect(CorpusHash.hash([a, b]).count == 64) // hex sha256
  // boundary-sensitive: length-prefix must separate parts, so re-splitting the same bytes differs
  #expect(CorpusHash.hash([Data("ab".utf8), Data("c".utf8)]) != CorpusHash.hash([Data("a".utf8), Data("bc".utf8)]))
}
