import Testing
@testable import PensieveKit

@Test func agreementRateCountsMatches() {
  let judge = [CandidateLabel(quote: "a", grounded: true), CandidateLabel(quote: "b", grounded: false)]
  let human = [CandidateLabel(quote: "a", grounded: true), CandidateLabel(quote: "b", grounded: true)]
  #expect(Agreement.rate(judge: judge, human: human) == 0.5)
}
@Test func agreementNilWhenNoOverlap() {
  #expect(Agreement.rate(judge: [], human: []) == nil)
}
