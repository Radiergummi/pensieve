import Testing
@testable import PensieveKit

private struct JSONProvider: LLMProvider {
  let json: String
  func complete(prompt: String) async throws -> String { json }
}

@Test func judgeDecodesRubricFromFencedJSON() async {
  let provider = JSONProvider(json: "```json\n{\"dimensionScores\":{\"grounded\":1.0,\"concise\":0.5},\"quality\":0.75}\n```")
  let rubricScore = await Judge(provider: provider).scoreRubric(output: "prose", dimensions: ["grounded", "concise"], sourceContext: "ctx")
  #expect(rubricScore?.quality == 0.75)
  #expect(rubricScore?.dimensionScores?["grounded"] == 1.0)
}

@Test func judgeLabelsGrounding() async {
  let provider = JSONProvider(json:
    "{\"candidateLabels\":[{\"quote\":\"revisit retries\",\"grounded\":true},{\"quote\":\"call Bob\",\"grounded\":false}]}")
  let looseEnd = [VerifiedLooseEnd(text: "t", quote: "revisit retries", role: "user", sourceMessageIndex: 0),
            VerifiedLooseEnd(text: "t2", quote: "call Bob", role: "user", sourceMessageIndex: 1)]
  let labels = await Judge(provider: provider).labelGrounding(looseEnds: looseEnd, source: "we should revisit retries")
  #expect(labels?.count == 2)
  #expect(labels?.first(where: { $0.quote == "call Bob" })?.grounded == false)
}

@Test func judgeReturnsNilOnGarbage() async {
  let rubricScore = await Judge(provider: JSONProvider(json: "not json at all"))
    .scoreRubric(output: "x", dimensions: ["a"], sourceContext: "c")
  #expect(rubricScore == nil)
}

@Test func judgeDecodeHandlesBracesInsideStrings() async {
  // A quote value containing { } [ ] must not desync the balanced scanner.
  let json = #"{"candidateLabels":[{"quote":"fix the { retry } loop [v2]","grounded":true}]}"#
  let provider = JSONProvider(json: json)
  let looseEnd = [VerifiedLooseEnd(text: "t", quote: "fix the { retry } loop [v2]", role: "user", sourceMessageIndex: 0)]
  let labels = await Judge(provider: provider).labelGrounding(looseEnds: looseEnd, source: "…")
  #expect(labels?.count == 1)
  #expect(labels?.first?.quote == "fix the { retry } loop [v2]")
  #expect(labels?.first?.grounded == true)
}

@Test func judgeDecodeHandlesEscapedQuoteInsideString() async {
  // An escaped double-quote inside a string value must not prematurely end the string.
  let json = #"{"candidateLabels":[{"quote":"he said \"stop\" then left","grounded":false}]}"#
  let provider = JSONProvider(json: json)
  let looseEnd = [VerifiedLooseEnd(text: "t", quote: "he said \"stop\" then left", role: "user", sourceMessageIndex: 0)]
  let labels = await Judge(provider: provider).labelGrounding(looseEnds: looseEnd, source: "…")
  #expect(labels?.count == 1)
  #expect(labels?.first?.quote == "he said \"stop\" then left")
  #expect(labels?.first?.grounded == false)
}
