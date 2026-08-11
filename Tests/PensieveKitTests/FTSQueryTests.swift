import Testing
@testable import PensieveKit

@Suite struct FTSQueryTests {
  @Test func singleTermGetsQuotedAndPrefixed() {
    #expect(FTSQueryBuilder.build("pens")?.shape == .textWithPathProbe("\"pens\"*"))
  }

  @Test func trailingSpaceMeansTheWordIsFinishedSoNoPrefix() {
    #expect(FTSQueryBuilder.build("pensieve ")?.shape == .textWithPathProbe("\"pensieve\""))
  }

  @Test func multipleTermsAreAndedAndOnlyTheLastIsAPrefix() {
    #expect(FTSQueryBuilder.build("focus filter spot")?.shape
            == .textWithPathProbe("\"focus\" AND \"filter\" AND \"spot\"*"))
  }

  @Test func apostropheIsNeutralised() {
    let built = FTSQueryBuilder.build("don't ")
    #expect(built?.shape == .textWithPathProbe("\"don't\""))
    #expect(built?.terms == ["don't"])
  }

  @Test func embeddedDoubleQuoteIsDoubled() {
    #expect(FTSQueryBuilder.build("say \"hi ")?.shape == .textWithPathProbe("\"say\" AND \"hi\""))
  }

  @Test func operatorCharactersAreLiteral() {
    #expect(FTSQueryBuilder.build("C++ ")?.shape == .textWithPathProbe("\"C++\""))
    #expect(FTSQueryBuilder.build("a:b ")?.shape == .textWithPathProbe("\"a:b\""))
    #expect(FTSQueryBuilder.build("* ")?.shape == .textWithPathProbe("\"*\""))
  }

  @Test func balancedPhraseStaysOnePhrase() {
    #expect(FTSQueryBuilder.build("\"background sync\" ")?.shape
            == .textWithPathProbe("\"background sync\""))
  }

  @Test func unbalancedQuoteTakesTheRestAsOnePhrase() {
    #expect(FTSQueryBuilder.build("\"background sync")?.shape
            == .textWithPathProbe("\"background sync\"*"))
  }

  /// Paths live in their own FTS5 table, so a `files:` directive with nothing else to match is a
  /// path-only query — a `files : …` clause against the text table is now a hard SQLite error.
  @Test func filesPrefixRoutesToTheFilesTable() {
    #expect(FTSQueryBuilder.build("files:SemanticQueries.swift ")?.shape
            == .pathOnly("\"SemanticQueries.swift\""))
  }

  /// An explicit restriction suppresses the opportunistic probe: text ranks, the path narrows.
  @Test func structuredFileParameterBecomesARestriction() {
    #expect(FTSQueryBuilder.build("refactor ", file: "Sources/A.swift")?.shape
            == .textRestrictedByPath(text: "\"refactor\"", path: "\"Sources/A.swift\""))
  }

  @Test func structuredFileParameterAloneIsAValidQuery() {
    #expect(FTSQueryBuilder.build("", file: "Sources/A.swift")?.shape
            == .pathOnly("\"Sources/A.swift\""))
  }

  /// Without an explicit directive the bare terms are ALSO tried against paths, so typing a bare
  /// filename still finds the commits that touched it.
  @Test func bareTermsGetAnOpportunisticPathProbe() {
    #expect(FTSQueryBuilder.build("syncrunner ")?.shape == .textWithPathProbe("\"syncrunner\""))
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
    #expect(FTSQueryBuilder.build("Lösung ")?.shape == .textWithPathProbe("\"Lösung\""))
    #expect(FTSQueryBuilder.build("設計 ")?.shape == .textWithPathProbe("\"設計\""))
    #expect(FTSQueryBuilder.build("🐛 ")?.shape == .textWithPathProbe("\"🐛\""))
  }
}
