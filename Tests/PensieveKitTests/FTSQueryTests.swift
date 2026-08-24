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
  }

  /// A word FTS5 cannot tokenize is dropped rather than quoted into an empty phrase.
  ///
  /// Measured against a real `unicode61 remove_diacritics 2` table — the tokenizer the index
  /// actually uses. Its vocabulary from `'Pensieve — search everything'` and `'a bug 🐛 here'` is
  /// `[a, bug, everything, here, pensieve, search]`: no `—`, no `*`, no emoji, because unicode61's
  /// token characters are exactly Unicode L*/N*/Co and everything else is a separator. So
  /// `MATCH '"*"'` is 0 rows and — the part that lost data — `MATCH '"bug" AND "🐛"'` is also
  /// **0 rows**, against a document containing both. One untokenizable word zeroed the whole
  /// conjunction.
  ///
  /// Dropping it means such a word alone yields nil (the caller shows "keep typing" rather than a
  /// false "no results"), and alongside real terms it simply stops destroying them.
  @Test func untokenizableWordsAreDroppedRatherThanZeroingTheQuery() {
    // Alone: nothing searchable was typed.
    #expect(FTSQueryBuilder.build("* ") == nil)
    #expect(FTSQueryBuilder.build("— ") == nil)
    #expect(FTSQueryBuilder.build("-> ") == nil)
    #expect(FTSQueryBuilder.build("... ") == nil)

    // Beside real terms: the real terms survive untouched. This is the regression that mattered —
    // `EmbeddableCorpus` joins a node as `name — description` and the app renders that same string,
    // so pasting a node title into search returned zero hits for its own indexed text.
    #expect(FTSQueryBuilder.build("Pensieve — search ")?.shape
            == .textWithPathProbe("\"Pensieve\" AND \"search\""))
    #expect(FTSQueryBuilder.build("client -> server ")?.shape
            == .textWithPathProbe("\"client\" AND \"server\""))
    #expect(FTSQueryBuilder.build("fix - ci ")?.shape
            == .textWithPathProbe("\"fix\" AND \"ci\""))

    // The dropped word must not leak into the highlight terms either.
    #expect(FTSQueryBuilder.build("Pensieve — search ")?.terms == ["Pensieve", "search"])

    // Trailing junk still leaves the last real word prefix-matched, as if it had not been typed.
    #expect(FTSQueryBuilder.build("hello ---")?.shape == .textWithPathProbe("\"hello\"*"))
  }

  /// A quoted phrase is only dropped when it is ENTIRELY untokenizable — such a phrase can never
  /// match any row, so ANDing it is guaranteed loss and never intent. A phrase that merely
  /// CONTAINS punctuation is still a phrase: verified 1 row for `MATCH '"Pensieve — search"'`.
  @Test func onlyWhollyUntokenizablePhrasesAreDropped() {
    #expect(FTSQueryBuilder.build("\"Pensieve — search\" ")?.shape
            == .textWithPathProbe("\"Pensieve — search\""))
    #expect(FTSQueryBuilder.build("\"—\" ") == nil)
    #expect(FTSQueryBuilder.build("real \"—\" ")?.shape == .textWithPathProbe("\"real\""))
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

  /// Letters are letters in every script — unicode61 treats all of Unicode L* as token characters,
  /// so CJK and diacritics survive. Emoji do NOT: they are category So, a separator, and the
  /// measured vocabulary of a document containing `🐛` holds no such term. An emoji query is
  /// therefore unanswerable by this index, and nil says so instead of returning a query that is
  /// guaranteed to match nothing — and instead of silently zeroing any real terms typed with it.
  @Test func unicodeInputSurvivesButEmojiIsNotTokenizable() {
    #expect(FTSQueryBuilder.build("Lösung ")?.shape == .textWithPathProbe("\"Lösung\""))
    #expect(FTSQueryBuilder.build("設計 ")?.shape == .textWithPathProbe("\"設計\""))
    #expect(FTSQueryBuilder.build("🐛 ") == nil)
    #expect(FTSQueryBuilder.build("bug 🐛 ")?.shape == .textWithPathProbe("\"bug\""))
  }
}
