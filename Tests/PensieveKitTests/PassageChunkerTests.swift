import Foundation
import Testing
@testable import PensieveKit

@Suite struct PassageChunkerTests {
  @Test func shortTextIsOneChunk() {
    let text = "why does the background sync agent refuse to spawn"
    #expect(PassageChunker.chunk(text) == [text])
  }

  /// The boundary itself, both sides. A 2,000-character text is ONE chunk; 2,001 splits.
  @Test func theSingleChunkLimitIsInclusive() {
    let atLimit = String(repeating: "a", count: 2000)
    #expect(PassageChunker.chunk(atLimit).count == 1)
    let overLimit = String(repeating: "a", count: 2001)
    #expect(PassageChunker.chunk(overLimit).count > 1)
  }

  /// Overlap is the whole point: a phrase straddling a boundary must be findable from one side.
  /// Asserted by CONTENT, not by counting — an off-by-one in the stride would still produce
  /// plausible-looking chunk counts.
  @Test func windowsOverlapSoAStraddlingPhraseSurvives() {
    // A distinctive phrase placed to straddle the first window's end.
    let filler = String(repeating: "x ", count: 745)          // 1490 chars
    let text = filler + "GHOST PHRASE HERE" + String(repeating: " y", count: 400)
    let chunks = PassageChunker.chunk(text)
    #expect(chunks.count > 1)
    #expect(chunks.contains { $0.contains("GHOST PHRASE HERE") },
            "the straddling phrase must appear intact in at least one chunk")
  }

  @Test func chunksSplitOnWhitespaceNotMidWord() {
    let word = "incomprehensibilities"
    let text = Array(repeating: word, count: 200).joined(separator: " ")
    let chunks = PassageChunker.chunk(text)
    #expect(chunks.count > 1)
    for chunk in chunks {
      let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
      #expect(!trimmed.isEmpty)
      // Every token in every chunk is the whole word — nothing was cut through.
      for token in trimmed.split(separator: " ") { #expect(token == word) }
    }
  }

  /// A pathological input with no whitespace at all must still terminate and still cover the text.
  @Test func textWithNoWhitespaceStillSplitsAndLosesNothing() {
    let text = String(repeating: "z", count: 5000)
    let chunks = PassageChunker.chunk(text)
    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.count <= PassageChunker.windowLength })
    // No-loss: every character position is covered by some chunk.
    #expect(chunks.joined().count >= text.count)
  }

  @Test func emptyAndWhitespaceOnlyTextYieldNoChunks() {
    #expect(PassageChunker.chunk("").isEmpty)
    #expect(PassageChunker.chunk("   \n  ").isEmpty)
  }
}
