// Task 12 — the pre-registered ranking gate for on-device translation joining the FTS5 index as its
// own document per item (see .superpowers/sdd/2026-08-12-on-device-translation/task-12-brief.md).
//
// Question: does a German translation document sharing its original's item_id measurably move
// English BM25 ranking, by shifting corpus-wide IDF/avgdl? Decision rule (fixed before measurement):
// if English P@1 in the treated arm is NOT significantly worse than the baseline arm (McNemar,
// p < 0.05, n = 1500), the design ships as built; if it IS, the pre-specified fallback (a separate
// FTS table per language) ships instead.
//
// Reuses rprobe4.swift's tokenizer, BM25 formula (k1=1.2, b=0.75, the same idf/tf-saturation) and
// P@1/P@5/MRR@50 aggregate computation, and its McNemar exact-test code, verbatim in spirit — a
// differently-computed metric would not be comparable to the committed 2026-07-28 figures. What is
// NEW here, because the treated arm's design requires it (not a methodology substitution): ranking
// works over item_ids rather than raw rows, because a translated document is a SEPARATE row sharing
// its original's item_id (Task 6/7). Two traps this must not fall into, both spelled out in the brief:
//   Trap 1 — the query sample is drawn ONCE from the baseline (English-only) corpus and reused
//            unchanged in both arms; no German document is ever used as a query.
//   Trap 2 — the ranked candidate list is collapsed by item_id (keeping each item's best rank) in
//            BOTH arms before scoring, exactly mirroring SearchQueries.buildHits's dedup. In the
//            baseline arm this is a no-op by construction (one row per item_id there).
import Foundation

let measureDirectory = ProcessInfo.processInfo.environment["PENSIEVE_MEASURE_DIR"]
  ?? FileManager.default.currentDirectoryPath

struct Doc { let kind: String; let itemID: String; let nodeID: String; let text: String; let language: String }

func loadCorpus(_ filename: String) -> [Doc] {
  guard let contents = try? String(contentsOfFile: "\(measureDirectory)/\(filename)", encoding: .utf8) else {
    return []
  }
  var docs: [Doc] = []
  for line in contents.split(separator: "\n") {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let kind = object["kind"] as? String, let itemID = object["itemID"] as? String,
          let nodeID = object["nodeID"] as? String, let text = object["text"] as? String, !text.isEmpty
    else { continue }
    docs.append(Doc(kind: kind, itemID: itemID, nodeID: nodeID, text: text,
                    language: (object["language"] as? String) ?? ""))
  }
  return docs
}

let baselineRaw = loadCorpus("corpus.jsonl")
let treatedRaw = loadCorpus("corpus_de.jsonl")
FileHandle.standardError.write("baseline raw docs: \(baselineRaw.count)   treated raw docs: \(treatedRaw.count)\n".data(using: .utf8)!)

// ---- Tokenizer — matches the shipped FTS5 tokenizer: `unicode61 remove_diacritics 2`, unstemmed.
// Byte-for-byte the same function as rprobe4.swift's `tok`.
func tok(_ s: String) -> [String] {
  s.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    .lowercased()
    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    .map(String.init)
    .filter { $0.count >= 2 }
}

// ---- Hygiene — drop bare `checkout <branch>` events, matching rprobe4.swift's own pass and
// `EmbeddableCorpus.gather`'s shipped P1 rule (both event-scoped). Documented as a no-op on the
// current corpus either way (gather() already drops these); kept so a regression would surface.
//
// Deliberately NARROWER than rprobe4.swift's own generic per-node text dedup, which applied to every
// kind, not just events: measured on this corpus, that generic rule drops 28 items from the TREATED
// arm and 0 from baseline — German node/loose-end documents that happen to collapse onto identical
// text within the SAME node (an unchanged proper noun translating to itself, or two distinct English
// loose ends translating to the same German rendering). That is a real property of translation, but
// it is not what `gather()` actually does: P1's dedup is event-only by design (its own doc comment),
// so widening it here would silently prune content production would index, bias the treated arm's
// composition toward LESS dilution than production, and read as a "does the design ship" result that
// is really a "did this probe's extra filter fire unevenly" result. Applying it only to events keeps
// both arms exactly what `gather()` would emit.
func applyHygiene(_ docs: [Doc]) -> [Doc] {
  docs.filter { !($0.kind == "event" && $0.text.hasPrefix("checkout ")) }
}
let baseline = applyHygiene(baselineRaw)
let treated = applyHygiene(treatedRaw)
print("== hygiene ==")
print("baseline: \(baselineRaw.count) -> \(baseline.count)   treated: \(treatedRaw.count) -> \(treated.count)")

// ---- Composition tables the README needs.
func composition(_ docs: [Doc], label: String) {
  var kindCounts: [String: Int] = [:]; var languageCounts: [String: Int] = [:]
  for d in docs { kindCounts[d.kind, default: 0] += 1; languageCounts[d.language, default: 0] += 1 }
  print("\(label) composition: total=\(docs.count) kinds=\(kindCounts.sorted { $0.key < $1.key }) " +
       "languages=\(languageCounts.sorted { $0.key < $1.key })")
}
composition(baseline, label: "baseline")
composition(treated, label: "treated")

// ---- Trap-3 (implicit) sanity: the treated arm must be baseline's item_ids plus extra German rows
// sharing them — never new item_ids, never fewer baseline (English) rows. Printed, not asserted, so a
// surprise is visible rather than crashing a long-running probe after translation already happened.
let baselineItemIDs = Set(baseline.map(\.itemID))
let treatedEnglishItemIDs = Set(treated.filter { $0.language.isEmpty }.map(\.itemID))
let treatedGermanItemIDs = Set(treated.filter { $0.language == "de" }.map(\.itemID))
print("== corpus-shape check ==")
print("baseline item_ids: \(baselineItemIDs.count)   treated English item_ids: \(treatedEnglishItemIDs.count) " +
     "(equal: \(baselineItemIDs == treatedEnglishItemIDs))")
print("treated German item_ids: \(treatedGermanItemIDs.count)   " +
     "all German item_ids are baseline item_ids: \(treatedGermanItemIDs.isSubset(of: baselineItemIDs))")

// ---- BM25 index, built once per arm. Formula and structure are rprobe4.swift's `cbm25` verbatim;
// `skip` widens from a single row index to a SET of row indices, because the treated arm's "self" can
// be two rows (the English original AND its German translation) sharing one item_id — Trap 2.
struct BM25Index {
  let docs: [Doc]
  let docTokens: [[String]]
  let termFrequency: [[String: Int]]
  let documentFrequency: [String: Int]
  let inverted: [String: [Int]]
  let averageDocumentLength: Double
  let documentCount: Double

  init(_ docs: [Doc]) {
    self.docs = docs
    docTokens = docs.map { tok($0.text) }
    var df: [String: Int] = [:]
    for tokens in docTokens { for word in Set(tokens) { df[word, default: 0] += 1 } }
    documentFrequency = df
    documentCount = Double(docs.count)
    averageDocumentLength = Double(docTokens.reduce(0) { $0 + $1.count }) / documentCount
    termFrequency = docTokens.map { tokens in
      var m: [String: Int] = [:]; for w in tokens { m[w, default: 0] += 1 }; return m
    }
    var inv: [String: [Int]] = [:]
    for (i, tokens) in docTokens.enumerated() { for w in Set(tokens) { inv[w, default: []].append(i) } }
    inverted = inv
  }

  /// Ranked (row index, score) pairs, descending, ties broken by index — identical to rprobe4's
  /// `cbm25`. `skip` rows are excluded from scoring entirely (never appear in the result), matching
  /// how rprobe4 excludes a query document from ranking against itself.
  func rank(_ query: String, skip: Set<Int>) -> [(Int, Double)] {
    let k1 = 1.2, b = 0.75
    var acc: [Int: Double] = [:]
    for word in Set(tok(query)) {
      guard let postings = inverted[word], let df = documentFrequency[word] else { continue }
      let idf = log(1 + (documentCount - Double(df) + 0.5) / (Double(df) + 0.5))
      for i in postings where !skip.contains(i) {
        let frequency = Double(termFrequency[i][word] ?? 0), length = Double(docTokens[i].count)
        acc[i, default: 0] += idf * (frequency * (k1 + 1)) /
          (frequency + k1 * (1 - b + b * length / averageDocumentLength))
      }
    }
    return acc.map { ($0.key, $0.value) }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
  }
}
let baselineIndex = BM25Index(baseline)
let treatedIndex = BM25Index(treated)

// item_id -> row indices, per arm (baseline: always exactly one; treated: one or two).
func rowsByItemID(_ docs: [Doc]) -> [String: [Int]] {
  var map: [String: [Int]] = [:]
  for (i, doc) in docs.enumerated() { map[doc.itemID, default: []].append(i) }
  return map
}
let baselineRowsByItemID = rowsByItemID(baseline)
let treatedRowsByItemID = rowsByItemID(treated)

/// Trap 2: collapse a ranked (row index, score) list to (item_id, score), keeping each item's FIRST
/// (best-ranked) occurrence. A no-op in the baseline arm (one row per item_id); in the treated arm a
/// German row of a relevant item collapses onto that item and correctly counts as a hit.
func dedupByItemID(_ ranked: [(Int, Double)], docs: [Doc]) -> [(String, Double)] {
  var seen = Set<String>(); var out: [(String, Double)] = []
  for (row, score) in ranked {
    let itemID = docs[row].itemID
    if seen.insert(itemID).inserted { out.append((itemID, score)) }
  }
  return out
}

/// Self-excluding, deduped ranking for one query, in one arm: exclude every row sharing the query's
/// own item_id (Trap 2's "a German row of the query item itself... stays excluded"), then dedup the
/// remainder by item_id.
func rankItems(_ index: BM25Index, rowsByItemID: [String: [Int]], queryText: String,
              queryItemID: String) -> [(String, Double)] {
  let skip = Set(rowsByItemID[queryItemID] ?? [])
  return dedupByItemID(index.rank(queryText, skip: skip), docs: index.docs)
}

// ---- Trap 1: the query sample is drawn ONCE from the BASELINE corpus, then reused unchanged in
// both arms. Eligibility (>=4 and <=200 items under a node) and the RNG are rprobe4.swift's own.
var byNode: [String: [String]] = [:]   // nodeID -> item_ids, baseline only
for doc in baseline { byNode[doc.nodeID, default: []].append(doc.itemID) }
let eligible = byNode.filter { $0.value.count >= 4 && $0.value.count <= 200 }
var randomState: UInt64 = 7
func nextRandom(_ n: Int) -> Int {
  randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
  return Int((randomState >> 33) % UInt64(n))
}
let eligibleNodeKeys = eligible.keys.sorted()
let queryCount = Int(ProcessInfo.processInfo.environment["PENSIEVE_MEASURE_N"] ?? "") ?? 1500
let eligibleTotal = eligible.values.reduce(0) { $0 + $1.count }
var querySample: [String] = []
var queryChosen = Set<String>()
while querySample.count < min(queryCount, eligibleTotal) {
  let nodeKey = eligibleNodeKeys[nextRandom(eligibleNodeKeys.count)]
  let candidates = eligible[nodeKey]!
  let pick = candidates[nextRandom(candidates.count)]
  if queryChosen.insert(pick).inserted { querySample.append(pick) }
}
print("\n== query sample (n=\(querySample.count), drawn once from baseline) ==")

let baselineDocByItemID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.itemID, $0) })
// Gold, per query: other item_ids under the same node, in the BASELINE item set, self excluded.
// Fixed once — identical for both arms, per Trap 1.
func gold(for queryItemID: String) -> Set<String> {
  let nodeID = baselineDocByItemID[queryItemID]!.nodeID
  return Set(byNode[nodeID]!).subtracting([queryItemID])
}

func evaluate(_ label: String, ranker: (String) -> [(String, Double)]) {
  var p1 = 0.0, p5 = 0.0, mrr = 0.0
  for queryItemID in querySample {
    let goldSet = gold(for: queryItemID)
    let ranked = ranker(queryItemID)
    if let top = ranked.first, goldSet.contains(top.0) { p1 += 1 }
    p5 += Double(ranked.prefix(5).filter { goldSet.contains($0.0) }.count) / 5.0
    if let position = ranked.prefix(50).firstIndex(where: { goldSet.contains($0.0) }) {
      mrr += 1 / Double(position + 1)
    }
  }
  let n = Double(querySample.count)
  print(label.padding(toLength: 12, withPad: " ", startingAt: 0) +
       String(format: "P@1=%.3f  P@5=%.3f  MRR@50=%.3f", p1 / n, p5 / n, mrr / n))
}

func baselineRank(_ queryItemID: String) -> [(String, Double)] {
  rankItems(baselineIndex, rowsByItemID: baselineRowsByItemID,
           queryText: baselineDocByItemID[queryItemID]!.text, queryItemID: queryItemID)
}
func treatedRank(_ queryItemID: String) -> [(String, Double)] {
  // The query text is ALWAYS the baseline (English) text — Trap 1: never a German document as query.
  rankItems(treatedIndex, rowsByItemID: treatedRowsByItemID,
           queryText: baselineDocByItemID[queryItemID]!.text, queryItemID: queryItemID)
}

evaluate("baseline", ranker: baselineRank)
evaluate("treated", ranker: treatedRank)

// ---- McNemar, paired on the identical n=1418 query sample (the corpus-size ceiling — 1,500 was the
// target, not the achieved count; see the README's Sample size section). Exact-test code is
// rprobe4.swift's own, verbatim (log-factorial two-sided exact binomial over the discordant pairs).
var onlyBaselineRight = 0, onlyTreatedRight = 0
for queryItemID in querySample {
  let goldSet = gold(for: queryItemID)
  let baselineRight = baselineRank(queryItemID).first.map { goldSet.contains($0.0) } ?? false
  let treatedRight = treatedRank(queryItemID).first.map { goldSet.contains($0.0) } ?? false
  if baselineRight && !treatedRight { onlyBaselineRight += 1 }
  if treatedRight && !baselineRight { onlyTreatedRight += 1 }
}
let discordant = onlyBaselineRight + onlyTreatedRight
func logFactorial(_ n: Int) -> Double { (1...max(n, 1)).reduce(0.0) { $0 + log(Double($1)) } }
func binomialProbability(_ k: Int, _ n: Int) -> Double {
  exp(logFactorial(n) - logFactorial(k) - logFactorial(n - k) - Double(n) * log(2))
}
let observed = min(onlyBaselineRight, onlyTreatedRight)
var pValue = 0.0
if discordant > 0 { for k in 0...observed { pValue += 2 * binomialProbability(k, discordant) } }
print(String(format: "\nMcNemar: baseline-only-right=%d  treated-only-right=%d  (discordant n=%d)  p=%.3f",
             onlyBaselineRight, onlyTreatedRight, discordant, min(pValue, 1.0)))
