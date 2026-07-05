// Tests/PensieveKitTests/CandidateFilterTests.swift
import Foundation
import Testing
@testable import PensieveKit

private func cand(_ quote: String) -> LooseEndCandidate {
  LooseEndCandidate(text: "paraphrase", quote: quote, messageIndex: 0)
}
private func quotesKept(_ quotes: [String]) -> [String] {
  CandidateFilter.strip(quotes.map(cand)).map(\.quote)
}

@Test func dropsPureClosuresAndStatusChecks() {
  let dropped = [
    "looks good, yes.", "all good, carry on", "sounds good, thanks",
    "are you done yet?", "is the research still running?", "what's the status?",
  ]
  #expect(quotesKept(dropped).isEmpty)
}

@Test func keepsClosurePrefixedDirectivesAndSubstantiveQuestions() {
  let kept = [
    "yes, let's fix 2 and 3 too",
    "approved, write up the spec",
    "can we fix this?",
    "still need to migrate the auth tables before launch",  // legit mid-sentence quote
    "are you done with the auth refactor and did you handle the migration?",  // substantive remainder
  ]
  #expect(Set(quotesKept(kept)) == Set(kept))
}

@Test func dropsChecklistAndToolOutputLinesButKeepsOpenTodos() {
  #expect(quotesKept(["✅ declare(strict_types=1); present"]).isEmpty)
  #expect(quotesKept(["❌ missing coverage on the error path"]).isEmpty)
  #expect(quotesKept(["@@ -1,4 +1,6 @@ func foo()"]).isEmpty)
  // An OPEN todo bullet is a REAL loose end — must be KEPT (not a completion marker).
  #expect(quotesKept(["- [ ] fix the flaky auth test"]) == ["- [ ] fix the flaky auth test"])
}
