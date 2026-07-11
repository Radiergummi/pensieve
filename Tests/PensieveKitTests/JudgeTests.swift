import Testing
@testable import PensieveKit

private struct JSONProvider: LLMProvider {
  let json: String
  func complete(prompt: String) async throws -> String { json }
}

@Test func judgeDecodesRubricFromFencedJSON() async {
  let p = JSONProvider(json: "```json\n{\"dimensionScores\":{\"grounded\":1.0,\"concise\":0.5},\"quality\":0.75}\n```")
  let v = await Judge(provider: p).scoreRubric(output: "prose", dimensions: ["grounded","concise"], sourceContext: "ctx")
  #expect(v?.quality == 0.75)
  #expect(v?.dimensionScores?["grounded"] == 1.0)
}

@Test func judgeLabelsGrounding() async {
  let p = JSONProvider(json: "{\"candidateLabels\":[{\"quote\":\"revisit retries\",\"grounded\":true},{\"quote\":\"call Bob\",\"grounded\":false}]}")
  let le = [VerifiedLooseEnd(text: "t", quote: "revisit retries", role: "user", sourceMessageIndex: 0),
            VerifiedLooseEnd(text: "t2", quote: "call Bob", role: "user", sourceMessageIndex: 1)]
  let labels = await Judge(provider: p).labelGrounding(looseEnds: le, source: "we should revisit retries")
  #expect(labels?.count == 2)
  #expect(labels?.first(where: { $0.quote == "call Bob" })?.grounded == false)
}

@Test func judgeReturnsNilOnGarbage() async {
  let v = await Judge(provider: JSONProvider(json: "not json at all")).scoreRubric(output: "x", dimensions: ["a"], sourceContext: "c")
  #expect(v == nil)
}
