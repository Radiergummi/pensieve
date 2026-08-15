// Sources/PensieveKit/Query/SearchQueries.swift
import Foundation
import SQLiteData

/// The filters a search applies AFTER the index returns candidates: which nodes are visible under
/// the active Focus, which item ids the caller already surfaced, how many hits to keep, and whether
/// archived content is eligible.
public struct SearchScope: Sendable {
  public var visibleNodeIDs: Set<UUID>
  public var excludingIDs: Set<UUID>
  public var limit: Int
  public var includeArchived: Bool
  /// Widen to closed (done/dropped) loose ends. Orthogonal to `includeArchived` in this kernel; the
  /// app's scope bar drives both from one control, which is a UI decision, not a model one.
  public var includeClosed: Bool
  public init(visibleNodeIDs: Set<UUID>, excludingIDs: Set<UUID> = [],
              limit: Int = SearchQueries.resultCap, includeArchived: Bool = false,
              includeClosed: Bool = false) {
    self.visibleNodeIDs = visibleNodeIDs
    self.excludingIDs = excludingIDs
    self.limit = limit
    self.includeArchived = includeArchived
    self.includeClosed = includeClosed
  }
}

/// Find across the grounded corpus: BM25 over the FTS5 index, joined back to the live canonical
/// store. This is the single retrieval path — the substring matcher it replaced could not see
/// events at all (64% of the corpus) and could not answer a multi-word query.
///
/// The index only decides which rows are ELIGIBLE. Every candidate is re-resolved against
/// canonical and re-checked against the same "is this still part of the live corpus" predicate the
/// index itself uses, so a between-sync stale row can never surface a dead hit. Best-effort: an
/// unavailable index or an untypeable query yields `[]`, never a throw.
///
/// There is no relevance floor. BM25 scores are unbounded and per-query-scaled, so a fixed cutoff
/// would be meaningless — relevance is bounded by rank plus the requirement that a document
/// actually contain the query's terms. **A rank cap is not a relevance threshold**; earning one is
/// what the paraphrase eval harness (spec P3) exists to decide.
public enum SearchQueries {
  public static let minQueryLength = 2
  public static let resultCap = 50
  /// Hard cap on the grow-`k` loop. Internal rather than private because `PassageQueries` runs the
  /// same loop over its own table and must stop at the same place — a second `2000` there is a
  /// magic number that would silently diverge.
  static let maxFetch = 2000

  public static func search(query rawQuery: String,
                            file: String? = nil,
                            scope: SearchScope,
                            store: SearchIndexStore,
                            translations: TranslationStore? = nil,
                            language: String = TranslationTarget.off,
                            _ database: any DatabaseReader) -> [SearchHit] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard store.isAvailable,
          let ftsQuery = FTSQueryBuilder.build(rawQuery, file: file) else { return [] }
    // A one-character query is noise on its own, but not when a path directive anchors it — and the
    // shape already tells us whether one is present, so there is no need to re-inspect `file` here.
    if case .textWithPathProbe = ftsQuery.shape, query.count < minQueryLength { return [] }

    // Over-fetch, and grow the window if post-index filtering (Focus-muting, exclusions, a stale
    // row) starved the result below `limit`. With no floor there is no early exit to be had: the
    // honest termination is "the index has no more rows" or the hard cap.
    var fetchCount = max(scope.limit * 8, 50)
    while true {
      let candidates = store.search(ftsQuery, limit: fetchCount,
                                    includeArchived: scope.includeArchived,
                                    includeClosed: scope.includeClosed)
      let hits = buildHits(candidates, terms: ftsQuery.terms, scope: scope,
                           translations: translations, language: language, database)
      if hits.count >= scope.limit || candidates.count < fetchCount || fetchCount >= maxFetch {
        return hits
      }
      fetchCount = min(fetchCount * 4, maxFetch)
    }
  }

  /// `search`, plus one retry in English when the literal query found nothing.
  ///
  /// A wrapper rather than a change to `search` for two reasons. `search` is synchronous and every
  /// caller depends on that; and keeping it byte-identical is what makes the safety property
  /// STRUCTURAL — this can never regress a query that already returns rows, because it only runs when
  /// the result was already empty.
  ///
  /// No language detection. Detection over a two-word query is unreliable, and it is unnecessary:
  /// translating an already-English query yields a no-op or nonsense, and since there was nothing to
  /// lose, nothing is lost. The residual value is over content that never gets a stored
  /// translation — commit subjects, event summaries, file paths — plus German compounding, where a
  /// typed `Hintergrundsync` misses a stored `Hintergrund-Synchronisierung` under AND semantics.
  public static func searchTranslatingOnEmpty(query rawQuery: String,
                                              file: String? = nil,
                                              scope: SearchScope,
                                              store: SearchIndexStore,
                                              translations: TranslationStore? = nil,
                                              language: String = TranslationTarget.off,
                                              translator: Translator? = nil,
                                              _ database: any DatabaseReader) async -> [SearchHit] {
    let hits = search(query: rawQuery, file: file, scope: scope, store: store,
                      translations: translations, language: language, database)
    guard hits.isEmpty,
          let english = await englishRetryQuery(for: rawQuery, language: language,
                                                translator: translator)
    else { return hits }
    return search(query: english, file: file, scope: scope, store: store,
                  translations: translations, language: language, database)
  }

  /// The English query to retry with, or nil when a retry is pointless or impossible: translation
  /// off, no translator, a query too short to translate meaningfully, a translation that failed, or
  /// one that came back unchanged.
  ///
  /// Split out so every retrieval path can apply the SAME retry policy — the passage path needs it
  /// at least as much as the ranked one, since transcripts are overwhelmingly English while the
  /// query may not be. Deciding *when* to retry is the part that must not be reimplemented; the
  /// two-line "run, and if empty run again" around it is each caller's own, and keeping it there is
  /// what preserves the structural safety property: a retry can never regress a query that already
  /// returned rows, because it only runs when the result was already empty.
  public static func englishRetryQuery(for rawQuery: String, language: String,
                                       translator: Translator?) async -> String? {
    guard !language.isEmpty, let translator else { return nil }
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= minQueryLength,
          let english = await translator.translate(query, from: language,
                                                   to: TranslationTarget.sourceLanguage),
          english.caseInsensitiveCompare(query) != .orderedSame
    else { return nil }
    return english
  }

  /// The node the user is most likely navigating to, selected by scanning the VISIBLE node set —
  /// never the returned hits. A node crowded out of the result cap by events is equally absent
  /// from any function of those hits, and that happens exactly on the common-term queries where
  /// navigation matters most. Callers pass their already-Focus-filtered, already-scoped nodes, so
  /// a muted node can never be pinned above a list that excludes it.
  public static func topHit(query rawQuery: String, in nodes: [Node]) -> SearchHit? {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= minQueryLength else { return nil }
    let match = nodes
      .filter { hasWordPrefix($0.name, prefix: query) }
      .min { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
    guard let match else { return nil }
    return SearchHit(id: match.id, kind: .node, nodeID: match.id, nodeName: match.name,
                     title: match.name,
                     snippet: SnippetMaker.make(from: match.name, matching: query),
                     score: nil, isArchived: match.state == .archived)
  }

  /// True when `prefix` starts the name or starts any word inside it, case- and
  /// diacritic-insensitively. Mid-word matches do not count — "racker" is not navigation intent.
  private static func hasWordPrefix(_ name: String, prefix: String) -> Bool {
    let options: String.CompareOptions = FindMatcher.options.union(.anchored)
    if name.range(of: prefix, options: options) != nil { return true }
    return name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .contains { $0.range(of: prefix, options: options) != nil }
  }

  /// Filter one index page down to at most `limit` grounded, visible, non-excluded hits, resolving
  /// each survivor against canonical via the shared `SearchHitResolver`. One read transaction for
  /// the whole page rather than one per candidate.
  private static func buildHits(_ candidates: [SearchIndexHit], terms: [String],
                                scope: SearchScope,
                                // These two defaults exist ONLY to keep this private function under
                                // SwiftLint's `function_parameter_count` cap (which excludes defaulted
                                // parameters from its count). The single call site below still passes
                                // both explicitly — a future second call site that omits them would
                                // compile but silently disable translation lookups for that caller.
                                translations: TranslationStore? = nil,
                                language: String = TranslationTarget.off,
                                _ database: any DatabaseReader) -> [SearchHit] {
    let resolver = SearchHitResolver(
      includeArchived: scope.includeArchived,
      includeClosed: scope.includeClosed,
      highlight: { SnippetMaker.make(from: $0, matchingAny: terms) },
      translations: { field, sourceText in
        guard let translations, !language.isEmpty else { return nil }
        return translations.translation(field: field, sourceText: sourceText, language: language)
      })
    // A failure here is failing to OPEN a canonical read — an app-wide condition, not a search
    // result — so it degrades to empty like every other read, but it is logged rather than mistaken
    // for "nothing matched". Per-candidate resolve failures stay silent and skip individually.
    do {
      return try database.read { database in
        var hits: [SearchHit] = []
        // One hit per item, even when both its language documents matched. Deduped BEFORE resolving
        // so a duplicate costs no canonical read. The `limit` shortfall this can cause is absorbed by
        // the caller's grow-`k` loop, which already exists for Focus-muting and stale rows.
        var seenItemIDs = Set<UUID>()
        for candidate in candidates {
          guard let kind = SearchHit.Kind(rawValue: candidate.kind),
                let nodeID = UUID(uuidString: candidate.nodeID),
                scope.visibleNodeIDs.contains(nodeID) else { continue }
          guard let itemID = UUID(uuidString: candidate.itemID),
                !scope.excludingIDs.contains(itemID) else { continue }
          guard seenItemIDs.insert(itemID).inserted else { continue }
          guard let hit = try? resolver.resolve(kind: kind, itemID: itemID, score: candidate.score,
                                                database) else { continue }
          hits.append(hit)
          if hits.count == scope.limit { break }
        }
        return hits
      }
    } catch {
      Log.search.error("SearchQueries: canonical read failed: \(error, privacy: .public)")
      return []
    }
  }
}
