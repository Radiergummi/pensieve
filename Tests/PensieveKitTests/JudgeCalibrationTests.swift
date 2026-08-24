import Foundation
import Testing
@testable import PensieveKit

// MARK: - The labelling queue

/// A fabricated quote cannot be typed in advance — it does not exist until a model invents one — so
/// the gold set's fabricated half can only come from what a sweep actually surfaced. This is the
/// mechanism that carries those quotes from a run to the human labelling them.
@Test func surfacedQuotesAccumulateAcrossRunsAndModels() {
  var surfaced = SurfacedQuotes()
  surfaced.merge(itemID: "item-1", quotes: ["a real quote", "a fabricated quote"])
  // A second model, same item: the union, deduped. Two models producing the same fabrication is one
  // thing to label, not two.
  surfaced.merge(itemID: "item-1", quotes: ["a real quote", "another fabrication"])
  #expect(surfaced.byItem["item-1"] == ["a fabricated quote", "a real quote", "another fabrication"])

  // Additive across runs: a fabrication produced last week is still worth having labelled, or the
  // gold set forgets it and the same regression walks back in unnoticed.
  var reloaded = SurfacedQuotes(byItem: surfaced.byItem)
  reloaded.merge(itemID: "item-1", quotes: ["a later fabrication"])
  #expect(reloaded.byItem["item-1"]?.count == 4)
}

@Test func theLabellingQueueIsWhatNoHumanHasAnsweredYet() {
  var surfaced = SurfacedQuotes()
  surfaced.merge(itemID: "item-1", quotes: ["known good", "never seen", "known bad"])
  let gold = GoldSet(recall: [:], grounding: [
    "item-1": [CandidateLabel(quote: "known good", grounded: true),
               CandidateLabel(quote: "known bad", grounded: false)],
  ])
  // Only the unanswered one. A labelled quote must not be re-asked — that is the whole point of
  // accumulating labels rather than re-labelling every sweep.
  #expect(surfaced.unlabelled(itemID: "item-1", gold: gold) == ["never seen"])
  // An item nobody has labelled at all yields everything, and an unknown item yields nothing.
  #expect(surfaced.unlabelled(itemID: "item-1", gold: GoldSet(recall: [:], grounding: [:])).count == 3)
  #expect(surfaced.unlabelled(itemID: "no-such-item", gold: gold).isEmpty)
}

// MARK: - Agreement

/// The number that says whether the judge could label a corpus without a human. It has to be earned
/// from adjudicated pairs, and it has to survive the same quote text appearing in two items.
@Test func judgeAgreementCountsOnlyQuotesBothSidesAnswered() {
  let gold = GoldSet(
    recall: [:],
    grounding: [
      "item-1": [CandidateLabel(quote: "alpha", grounded: true),
                 CandidateLabel(quote: "beta", grounded: false),
                 CandidateLabel(quote: "unjudged", grounded: true)],
    ],
    judgeGrounding: [
      "item-1": [CandidateLabel(quote: "alpha", grounded: true),      // agrees
                 CandidateLabel(quote: "beta", grounded: true)],      // disagrees
    ])
  // 1 of the 2 adjudicated quotes. "unjudged" has no judge label and must not count as agreement —
  // silently scoring an unanswered quote as a match is how a judge looks better than it is.
  #expect(gold.judgeAgreement() == 0.5)
}

/// Regression guard for the bug this was written with — and the fixture matters, because the obvious
/// one does not catch it.
///
/// `Agreement.rate` keys on quote TEXT alone, so comparing a flattened judge list against a flattened
/// human list collapses the same sentence appearing in two items into one key, and `uniquingKeysWith`
/// keeps whichever verdict came first. A fixture where the JUDGE says the same thing in both items is
/// blind to this: the surviving key is correct either way, and flattened and per-item both report the
/// same number (verified by mutation — the flattened implementation passed it).
///
/// It only bites when the judge disagrees with ITSELF across items, which is normal — the same
/// sentence really can be grounded in one transcript and fabricated in another. Then the flattened
/// result depends on `Dictionary` ordering: it is 100% or 0%, arbitrarily, and never the truth.
@Test func theSameQuoteInTwoItemsIsJudgedPerItemNotPooledByText() {
  let shared = "we should probably fix the sync bug"
  let gold = GoldSet(
    recall: [:],
    grounding: [
      "item-1": [CandidateLabel(quote: shared, grounded: true)],
      "item-2": [CandidateLabel(quote: shared, grounded: true)],
    ],
    judgeGrounding: [
      "item-1": [CandidateLabel(quote: shared, grounded: true)],     // agrees with its human
      "item-2": [CandidateLabel(quote: shared, grounded: false)],    // disagrees with its human
    ])
  // One right, one wrong, judged where each was actually asked. The flattened comparison reports
  // 100% or 0% depending on which verdict `uniquingKeysWith` happened to keep — never 50%.
  #expect(gold.judgeAgreement() == 0.5)
}

@Test func agreementIsNilRatherThanPerfectWhenNothingWasAdjudicated() {
  let neverJudged = GoldSet(recall: [:], grounding: [
    "item-1": [CandidateLabel(quote: "alpha", grounded: true)],
  ])
  // nil, not 1.0: "no judge has ever been checked" and "the judge was always right" are opposite
  // claims, and only one of them licenses trusting it to label a corpus.
  #expect(neverJudged.judgeAgreement() == nil)
  #expect(GoldSet(recall: [:], grounding: [:]).judgeAgreement() == nil)
}

// MARK: - Backward compatibility

/// A gold.json written before judge labels existed must still load — it simply has none.
@Test func aGoldSetWithoutJudgeLabelsStillDecodes() throws {
  let legacy = #"{"recall":{"i":["q"]},"grounding":{"i":[{"quote":"q","grounded":true}]}}"#
  let decoded = try JSONDecoder().decode(GoldSet.self, from: Data(legacy.utf8))
  #expect(decoded.recall["i"] == ["q"])
  #expect(decoded.judgeGrounding.isEmpty)
  #expect(decoded.judgeAgreement() == nil)
}
