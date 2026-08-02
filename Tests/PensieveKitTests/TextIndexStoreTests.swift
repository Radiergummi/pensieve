import Testing
import Foundation
@testable import PensieveKit

@Suite struct TextIndexStoreTests {
  private func store() -> TextIndexStore {
    TextIndexStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("txtidx-\(UUID().uuidString).sqlite"))
  }

  private func item(_ id: String, _ text: String, state: String = "active",
                    kind: String = "event", node: String = "N1") -> EmbeddableItem {
    EmbeddableItem(itemID: id, kind: kind, nodeID: node, state: state, text: text)
  }

  // MARK: match expression

  /// Every term is quoted so a user typing an FTS5 keyword gets a literal match instead of a
  /// syntax error or a silent operator. Terms are OR-ed, matching the spec's measurement config.
  @Test func matchExpressionQuotesTermsAndOrsThem() {
    #expect(TextIndexStore.matchExpression(for: "background sync") == "\"background\" OR \"sync\"")
  }

  @Test func matchExpressionTreatsFTS5KeywordsAsLiterals() {
    #expect(TextIndexStore.matchExpression(for: "cats AND dogs") == "\"cats\" OR \"and\" OR \"dogs\"")
  }

  /// Punctuation is a separator (mirroring unicode61) and 1-character tokens are dropped.
  @Test func matchExpressionSplitsOnPunctuationAndDropsShortTokens() {
    #expect(TextIndexStore.matchExpression(for: "login-items: a v2!") == "\"login\" OR \"items\" OR \"v2\"")
  }

  @Test func matchExpressionDedupesRepeatedTermsPreservingOrder() {
    #expect(TextIndexStore.matchExpression(for: "sync sync agent") == "\"sync\" OR \"agent\"")
  }

  /// Nothing usable → nil, so the caller returns [] instead of handing FTS5 an empty MATCH
  /// (which is a syntax error).
  @Test func matchExpressionIsNilWhenNothingUsableSurvives() {
    #expect(TextIndexStore.matchExpression(for: "  ") == nil)
    #expect(TextIndexStore.matchExpression(for: "a ? !") == nil)
  }

  /// A pasted paragraph must not build an unbounded OR chain (SQLITE_MAX_EXPR_DEPTH).
  @Test func matchExpressionCapsTermCount() {
    let raw = (1...100).map { "term\($0)" }.joined(separator: " ")
    let expr = TextIndexStore.matchExpression(for: raw)
    #expect(expr?.components(separatedBy: " OR ").count == 32)
  }

  // MARK: search

  @Test func searchRanksTheDocumentContainingMoreQueryTermsFirst() {
    let s = store()
    s.rebuild(items: [
      item("A", "background sync agent registers with login items"),
      item("B", "the sync daemon interval"),
      item("C", "unrelated transcript rendering work"),
    ])
    let hits = s.search(query: "background sync login", k: 10, includeArchived: false)
    #expect(hits.first?.itemID == "A")
    #expect(!hits.contains { $0.itemID == "C" })   // shares no query term
  }

  /// Higher score = more relevant, so the caller can sort/compare without knowing bm25()'s sign.
  @Test func searchScoresDescend() {
    let s = store()
    s.rebuild(items: [
      item("A", "background sync agent login items"),
      item("B", "sync"),
    ])
    let hits = s.search(query: "background sync login", k: 10, includeArchived: false)
    #expect(hits.count == 2)
    #expect(hits[0].score > hits[1].score)
  }

  @Test func searchCarriesKindAndNodeIDThrough() {
    let s = store()
    s.rebuild(items: [item("A", "refund rounding", kind: "loose_end", node: "NODE-7")])
    let hit = s.search(query: "refund", k: 5, includeArchived: false).first
    #expect(hit?.kind == "loose_end")
    #expect(hit?.nodeID == "NODE-7")
  }

  @Test func searchRespectsK() {
    let s = store()
    s.rebuild(items: (1...10).map { item("I\($0)", "sync item \($0)") })
    #expect(s.search(query: "sync", k: 3, includeArchived: false).count == 3)
  }

  @Test func searchReturnsEmptyForAnUnusableQuery() {
    let s = store()
    s.rebuild(items: [item("A", "background sync")])
    #expect(s.search(query: "  ", k: 5, includeArchived: false).isEmpty)
    #expect(s.search(query: "sync", k: 0, includeArchived: false).isEmpty)
  }

  // MARK: state filtering (allow-list, mirroring SemanticIndexStore.knn)

  @Test func searchExcludesArchivedByDefaultAndIncludesItWhenAsked() {
    let s = store()
    s.rebuild(items: [
      item("ACT", "sync agent work", state: "active"),
      item("ARC", "sync agent work archived", state: "archived"),
    ])
    let strict = s.search(query: "sync", k: 10, includeArchived: false).map { $0.itemID }
    #expect(strict == ["ACT"])
    let wide = Set(s.search(query: "sync", k: 10, includeArchived: true).map { $0.itemID })
    #expect(wide == ["ACT", "ARC"])
  }

  /// The filter is an allow-list, never a deny-list — an unknown/future state can't leak in by
  /// omission. (`muted` is never gathered, but the store must not depend on that.)
  @Test func searchNeverReturnsUnknownStates() {
    let s = store()
    s.rebuild(items: [
      item("ACT", "sync agent work", state: "active"),
      item("MUT", "sync agent muted", state: "muted"),
      item("FUT", "sync agent future", state: "somethingNew"),
    ])
    #expect(s.search(query: "sync", k: 10, includeArchived: true).map { $0.itemID } == ["ACT"])
  }

  // MARK: rebuild

  @Test func rebuildReplacesTheWholeIndex() {
    let s = store()
    s.rebuild(items: [item("OLD", "legacy invoices")])
    s.rebuild(items: [item("NEW", "legacy invoices")])
    let hits = s.search(query: "invoices", k: 10, includeArchived: false)
    #expect(hits.map { $0.itemID } == ["NEW"])
  }

  /// The fingerprint short-circuit: an unchanged corpus must not rewrite the table (the app
  /// rebuilds on every refresh; the daemon every 300 s).
  @Test func rebuildIsANoOpWhenTheCorpusIsUnchanged() {
    let s = store()
    let corpus = [item("A", "background sync"), item("B", "login items")]
    #expect(s.rebuild(items: corpus) == true)
    #expect(s.rebuild(items: corpus) == false)
  }

  /// State and node id are part of the fingerprint, not just the text hash — an archive flip or a
  /// strand repoint changes filter/attribution columns and must re-index.
  @Test func rebuildDetectsStateAndNodeChangesWithUnchangedText() {
    let s = store()
    #expect(s.rebuild(items: [item("A", "background sync", state: "active")]) == true)
    #expect(s.rebuild(items: [item("A", "background sync", state: "archived")]) == true)
    #expect(s.rebuild(items: [item("A", "background sync", state: "archived", node: "N2")]) == true)
  }

  /// Order is not identity: the same set gathered in a different order is the same corpus.
  @Test func rebuildFingerprintIsOrderIndependent() {
    let s = store()
    let a = item("A", "background sync"), b = item("B", "login items")
    #expect(s.rebuild(items: [a, b]) == true)
    #expect(s.rebuild(items: [b, a]) == false)
  }

  @Test func rebuildWithAnEmptyCorpusClearsTheIndex() {
    let s = store()
    s.rebuild(items: [item("A", "background sync")])
    s.rebuild(items: [])
    #expect(s.search(query: "sync", k: 10, includeArchived: false).isEmpty)
  }

  /// Survives a reopen: the index is a file, and a second process (app vs. daemon vs. MCP) must
  /// see the same rows AND the same fingerprint (no spurious rebuild on every process start).
  @Test func indexAndFingerprintSurviveAReopen() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("txtidx-reopen-\(UUID().uuidString).sqlite")
    let corpus = [item("A", "background sync agent")]
    #expect(TextIndexStore(url: url).rebuild(items: corpus) == true)

    let reopened = TextIndexStore(url: url)
    #expect(reopened.search(query: "sync", k: 5, includeArchived: false).map { $0.itemID } == ["A"])
    #expect(reopened.rebuild(items: corpus) == false)
  }

  /// Best-effort: a path that cannot be opened disables the store instead of throwing, and every
  /// op no-ops. The path must be unopenable even AFTER the delete-and-retry recovery — a directory
  /// sitting at the db path would simply be deleted and the retry would succeed. A path under
  /// `/dev/null` (a character device) can never hold a directory, so both attempts fail.
  @Test func anUnopenablePathDisablesTheStore() {
    let s = TextIndexStore(url: URL(fileURLWithPath: "/dev/null/nope/text-index.sqlite"))
    #expect(s.isAvailable == false)
    #expect(s.rebuild(items: [item("A", "x")]) == false)
    #expect(s.search(query: "sync", k: 5, includeArchived: false).isEmpty)
  }
}
