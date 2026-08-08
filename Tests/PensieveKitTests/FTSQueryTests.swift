import Testing
@testable import PensieveKit

@Suite struct FTSQueryTests {
  @Test func singleTermGetsQuotedAndPrefixed() {
    #expect(FTSQueryBuilder.build("pens")?.match == "\"pens\"*")
  }

  @Test func trailingSpaceMeansTheWordIsFinishedSoNoPrefix() {
    #expect(FTSQueryBuilder.build("pensieve ")?.match == "\"pensieve\"")
  }

  @Test func multipleTermsAreAndedAndOnlyTheLastIsAPrefix() {
    #expect(FTSQueryBuilder.build("focus filter spot")?.match
            == "\"focus\" AND \"filter\" AND \"spot\"*")
  }

  @Test func apostropheIsNeutralised() {
    let built = FTSQueryBuilder.build("don't ")
    #expect(built?.match == "\"don't\"")
    #expect(built?.terms == ["don't"])
  }

  @Test func embeddedDoubleQuoteIsDoubled() {
    #expect(FTSQueryBuilder.build("say \"hi ")?.match == "\"say\" AND \"hi\"")
  }

  @Test func operatorCharactersAreLiteral() {
    #expect(FTSQueryBuilder.build("C++ ")?.match == "\"C++\"")
    #expect(FTSQueryBuilder.build("a:b ")?.match == "\"a:b\"")
    #expect(FTSQueryBuilder.build("* ")?.match == "\"*\"")
  }

  @Test func balancedPhraseStaysOnePhrase() {
    #expect(FTSQueryBuilder.build("\"background sync\" ")?.match == "\"background sync\"")
  }

  @Test func unbalancedQuoteTakesTheRestAsOnePhrase() {
    #expect(FTSQueryBuilder.build("\"background sync")?.match == "\"background sync\"*")
  }

  /// Paths live in their own FTS5 table, so a `files:` directive leaves in `filesFilter`, not in
  /// the text `match` — a `files : …` clause against the text table is now a hard SQLite error.
  @Test func filesPrefixRoutesToTheFilesTable() {
    let built = FTSQueryBuilder.build("files:SemanticQueries.swift ")
    #expect(built?.match == "")
    #expect(built?.filesFilter == "\"SemanticQueries.swift\"")
    #expect(built?.filesProbe == nil)
  }

  @Test func structuredFileParameterBecomesARestriction() {
    let built = FTSQueryBuilder.build("refactor ", file: "Sources/A.swift")
    #expect(built?.match == "\"refactor\"")
    #expect(built?.filesFilter == "\"Sources/A.swift\"")
    #expect(built?.filesProbe == nil)   // an explicit restriction suppresses the opportunistic probe
  }

  @Test func structuredFileParameterAloneIsAValidQuery() {
    let built = FTSQueryBuilder.build("", file: "Sources/A.swift")
    #expect(built?.match == "")
    #expect(built?.filesFilter == "\"Sources/A.swift\"")
  }

  /// Without an explicit directive the bare terms are ALSO tried against paths, so typing a bare
  /// filename still finds the commits that touched it.
  @Test func bareTermsGetAnOpportunisticPathProbe() {
    let built = FTSQueryBuilder.build("syncrunner ")
    #expect(built?.match == "\"syncrunner\"")
    #expect(built?.filesProbe == "\"syncrunner\"")
    #expect(built?.filesFilter == nil)
  }

  @Test func emptyAndWhitespaceOnlyYieldNil() {
    #expect(FTSQueryBuilder.build("") == nil)
    #expect(FTSQueryBuilder.build("   ") == nil)
    #expect(FTSQueryBuilder.build("\"\"") == nil)
  }

  @Test func termsAreExposedForSnippetHighlighting() {
    #expect(FTSQueryBuilder.build("focus filter")?.terms == ["focus", "filter"])
  }

  @Test func unicodeInputSurvives() {
    #expect(FTSQueryBuilder.build("Lösung ")?.match == "\"Lösung\"")
    #expect(FTSQueryBuilder.build("設計 ")?.match == "\"設計\"")
    #expect(FTSQueryBuilder.build("🐛 ")?.match == "\"🐛\"")
  }
}
