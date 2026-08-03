import Foundation
import Testing
@testable import PensieveKit

private struct FixedProvider: LLMProvider {
  let reply: String
  func complete(prompt: String) async throws -> String { reply }
}

private func msg(_ index: Int, _ text: String) -> TranscriptMessage {
  TranscriptMessage(index: index, role: "user", text: text, timestamp: nil, isUserPrompt: true)
}

@Test func classifierKeepsOnlyReturnedIndices() async {
  let messages = [msg(0, "are we ready to roll this out?"),
                  msg(3, "You are taking over a completed feature branch. Your job is …")]
  let classifier = IntentClassifier(provider: FixedProvider(reply: "keep: [0]"))
  let kept = await classifier.filterGenuine(messages)
  #expect(kept.map(\.index) == [0])   // the brief (index 3) is dropped
}

@Test func classifierFailsOpenOnUnparseableOutput() async {
  let messages = [msg(0, "hello"), msg(1, "world")]
  let classifier = IntentClassifier(provider: FixedProvider(reply: "sorry, I can't do that"))
  let kept = await classifier.filterGenuine(messages)
  #expect(kept.map(\.index) == [0, 1])   // no parseable index array -> keep all
}

@Test func classifierHonorsStructuredEmptyAsDropAll() async {
  // A provider whose `complete` would fail open (unparseable -> keep all) but whose
  // structured method returns an empty array. The classifier must trust the structured
  // answer and drop all — proving guided output takes effect and fail-open is throw-only.
  struct DropAllStructured: LLMProvider {
    func complete(prompt: String) async throws -> String { "not parseable" }
    func classifyGenuineIndices(prompt: String) async throws -> [Int] { [] }
  }
  let messages = [msg(0, "hello"), msg(1, "world")]
  let kept = await IntentClassifier(provider: DropAllStructured()).filterGenuine(messages)
  #expect(kept.isEmpty)
}

@Test func classifierEmptyInputYieldsEmpty() async {
  let classifier = IntentClassifier(provider: FixedProvider(reply: "[]"))
  let kept = await classifier.filterGenuine([])
  #expect(kept.isEmpty)
}

@Test func decodeIndicesParsesOnlyIntArrays() {
  #expect(IntentClassifier.decodeIndices("[0, 2, 5]") == Set([0, 2, 5]))
  #expect(IntentClassifier.decodeIndices("The genuine ones are: [1,4]") == Set([1, 4]))
  // A candidate object-array (what the extractor returns) is NOT an int array -> nil (fail open).
  #expect(IntentClassifier.decodeIndices(#"[{"text":"t","messageIndex":0}]"#) == nil)
  #expect(IntentClassifier.decodeIndices("no array here") == nil)
  // Trailing prose containing ']' must not break the parse (regression: last-']' slice).
  #expect(IntentClassifier.decodeIndices("[0,2] because item 3 was already done ]") == Set([0, 2]))
}
