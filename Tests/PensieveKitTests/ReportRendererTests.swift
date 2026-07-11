// Tests/PensieveKitTests/ReportRendererTests.swift
import Testing
@testable import PensieveKit

@Test func markdownIncludesRecommendationAndCaveats() {
  let cells = [CellScore(modelLabel: "apple/fm", isOnDevice: true, quality: 0.8, precision: nil, recall: nil, costUSD: 0, latencyP50: 900, reproducedFabrication: false)]
  let rec = Recommendation(task: "narration", winner: "apple/fm", clearedBar: ["apple/fm"], reason: "incumbent clears")
  let sc = Scorecard(corpusHash: "abc123", tasks: [TaskScorecard(task: "narration", cells: cells, recommendation: rec, judgeAgreement: 0.9)])
  let md = ReportRenderer.markdown(sc)
  #expect(md.contains("abc123"))                 // corpus hash recorded
  #expect(md.contains("apple/fm"))               // model row
  #expect(md.contains("Recommended: apple/fm"))  // recommendation surfaced
  #expect(md.contains("estimate"))               // cost-estimate caveat present
  #expect(md.contains("not like-for-like"))      // latency caveat present
}
