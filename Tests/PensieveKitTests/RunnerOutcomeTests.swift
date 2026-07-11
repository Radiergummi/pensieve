import Testing
@testable import PensieveKit

@Test func classifyMapsErrors() {
  #expect(RunOutcome.classify(nil) == "success")
  #expect(RunOutcome.classify(LLMError.providerFailed("not a parseable index array")) == "parseFail")
  #expect(RunOutcome.classify(LLMError.providerFailed("HTTP 500")) == "providerError")
}
