// Tests/PensieveKitTests/CorpusHashTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Test func hashIsStableAndOrderSensitive() {
  let firstData = Data("one".utf8), secondData = Data("two".utf8)
  #expect(CorpusHash.hash([firstData, secondData]) == CorpusHash.hash([firstData, secondData]))
  #expect(CorpusHash.hash([firstData, secondData]) != CorpusHash.hash([secondData, firstData]))
  #expect(CorpusHash.hash([firstData, secondData]).count == 64) // hex sha256
  // boundary-sensitive: length-prefix must separate parts, so re-splitting the same bytes differs
  #expect(CorpusHash.hash([Data("ab".utf8), Data("c".utf8)]) != CorpusHash.hash([Data("a".utf8), Data("bc".utf8)]))
}
