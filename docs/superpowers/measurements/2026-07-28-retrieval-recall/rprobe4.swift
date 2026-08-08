// Part 2: a large-n, LLM-free, non-circular gold set the spec never considered —
// "same-node relatedness" (exactly what ⌘F "Related" is for), plus hybrid RRF.
import Foundation
import NaturalLanguage

let SP = ProcessInfo.processInfo.environment["PENSIEVE_MEASURE_DIR"] ?? FileManager.default.currentDirectoryPath
struct Doc { let kind: String; let itemID: String; let nodeID: String; let text: String; let files: String }

var docs: [Doc] = []
if let s = try? String(contentsOfFile: "\(SP)/corpus.jsonl", encoding: .utf8) {
  for line in s.split(separator: "\n") {
    guard let d = line.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let k = o["kind"] as? String, let i = o["itemID"] as? String,
          let n = o["nodeID"] as? String, let t = o["text"] as? String, !t.isEmpty else { continue }
    docs.append(Doc(kind: k, itemID: i, nodeID: n, text: t, files: (o["files"] as? String) ?? ""))
  }
}
FileHandle.standardError.write("docs \(docs.count)\n".data(using: .utf8)!)

guard let model = NLContextualEmbedding(script: .latin) else { fatalError("no model") }
try model.load()
func embed(_ text: String) -> [Float]? {
  guard let r = try? model.embeddingResult(for: text, language: nil) else { return nil }
  var toks: [[Float]] = []
  r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in toks.append(v.map { Float($0) }); return true }
  guard !toks.isEmpty else { return nil }
  let dim = toks[0].count
  var m = [Float](repeating: 0, count: dim)
  for t in toks { for i in 0..<dim { m[i] += t[i] } }
  for i in 0..<dim { m[i] /= Float(toks.count) }
  var nn: Float = 0; for v in m { nn += v * v }; nn = nn.squareRoot()
  return nn > 0 ? m.map { $0 / nn } : nil
}

// vector cache so repeated runs are cheap
let cacheURL = URL(fileURLWithPath: "\(SP)/vec.cache")
var vecs: [[Float]] = []; var kept: [Doc] = []
let dim = 512
if let d = try? Data(contentsOf: cacheURL), d.count % (dim * 4) == 0, d.count / (dim * 4) == docs.count {
  FileHandle.standardError.write("cache hit\n".data(using: .utf8)!)
  d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
    let f = p.bindMemory(to: Float.self)
    for i in 0..<docs.count { vecs.append(Array(f[(i*dim)..<((i+1)*dim)])) }
  }
  kept = docs
} else {
  var blob = Data()
  for (i, d) in docs.enumerated() {
    guard let v = embed(d.text) else { continue }
    vecs.append(v); kept.append(d)
    v.withUnsafeBufferPointer { blob.append(Data(buffer: $0)) }
    if i % 500 == 0 { FileHandle.standardError.write("  \(i)\n".data(using: .utf8)!) }
  }
  if kept.count == docs.count { try? blob.write(to: cacheURL) }
}
FileHandle.standardError.write("vecs \(vecs.count)\n".data(using: .utf8)!)

var mean = [Float](repeating: 0, count: dim)
for v in vecs { for i in 0..<dim { mean[i] += v[i] } }
for i in 0..<dim { mean[i] /= Float(vecs.count) }
func renorm(_ v: [Float]) -> [Float] { var n: Float = 0; for x in v { n += x*x }; n = n.squareRoot(); return n>0 ? v.map{$0/n} : v }
let centred = vecs.map { v in renorm((0..<dim).map { v[$0] - mean[$0] }) }
func cosf(_ a: [Float], _ b: [Float]) -> Double { var s: Float = 0; for i in 0..<dim { s += a[i]*b[i] }; return Double(s) }

// Matches the shipped FTS5 tokenizer: `unicode61 remove_diacritics 2`, unstemmed.
// The ≥2-char filter is a probe-only divergence (FTS5 indexes 1-char tokens); immaterial to ranking.
func tok(_ s: String) -> [String] {
  s.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    .lowercased()
    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    .map(String.init)
    .filter { $0.count >= 2 }
}
let docToks = kept.map { tok($0.text) }
var df: [String: Int] = [:]
for t in docToks { for w in Set(t) { df[w, default: 0] += 1 } }
let N = Double(kept.count)
let avgdl = Double(docToks.reduce(0) { $0 + $1.count }) / N
let tf: [[String: Int]] = docToks.map { d in var m: [String: Int] = [:]; for w in d { m[w, default: 0] += 1 }; return m }
// inverted index so BM25 is fast enough for 300 queries
var inv: [String: [Int]] = [:]
for (i, t) in docToks.enumerated() { for w in Set(t) { inv[w, default: []].append(i) } }

func bm25(_ q: String, skip: Int) -> [(Int, Double)] {
  let k1 = 1.2, b = 0.75
  var acc: [Int: Double] = [:]
  for w in Set(tok(q)) {
    guard let post = inv[w], let d = df[w] else { continue }
    let idf = log(1 + (N - Double(d) + 0.5) / (Double(d) + 0.5))
    for i in post where i != skip {
      let f = Double(tf[i][w] ?? 0), dl = Double(docToks[i].count)
      acc[i, default: 0] += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * dl / avgdl))
    }
  }
  return acc.map { ($0.key, $0.value) }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
}
func vrank(_ q: String, _ space: [[Float]], centring: Bool, skip: Int) -> [(Int, Double)] {
  guard var qv = embed(q) else { return [] }
  if centring { qv = renorm((0..<dim).map { qv[$0] - mean[$0] }) }
  return (0..<space.count).filter { $0 != skip }.map { ($0, cosf(qv, space[$0])) }.sorted { $0.1 > $1.1 }
}
func rrf(_ a: [(Int, Double)], _ b: [(Int, Double)], k: Double = 60) -> [(Int, Double)] {
  var s: [Int: Double] = [:]
  for (r, e) in a.prefix(200).enumerated() { s[e.0, default: 0] += 1 / (k + Double(r + 1)) }
  for (r, e) in b.prefix(200).enumerated() { s[e.0, default: 0] += 1 / (k + Double(r + 1)) }
  return s.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
}

// ---- CORPUS HYGIENE: drop bare `checkout <branch>` events + exact-duplicate texts WITHIN a node
// (shipped rule: per-node de-dup, not global — see spec §P1) ----
var seen = Set<String>(); var keepIdx: [Int] = []
for (i, d) in kept.enumerated() {
  if d.kind == "event" && d.text.hasPrefix("checkout ") { continue }
  let norm = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
  let key = "\(d.nodeID)\u{0}\(norm)"
  if seen.contains(key) { continue }
  seen.insert(key); keepIdx.append(i)
}
print("== corpus hygiene ==")
print("before: \(kept.count) docs   after dropping checkout events + exact dupes: \(keepIdx.count)")

let ckept = keepIdx.map { kept[$0] }
let cvecs = keepIdx.map { vecs[$0] }
let cdim = dim
var cmean = [Float](repeating: 0, count: cdim)
for v in cvecs { for i in 0..<cdim { cmean[i] += v[i] } }
for i in 0..<cdim { cmean[i] /= Float(cvecs.count) }

let cdocToks = ckept.map { tok($0.text) }
var cdf: [String: Int] = [:]
for t in cdocToks { for w in Set(t) { cdf[w, default: 0] += 1 } }
let cN = Double(ckept.count)
let cavgdl = Double(cdocToks.reduce(0) { $0 + $1.count }) / cN
let ctf: [[String: Int]] = cdocToks.map { d in var m: [String: Int] = [:]; for w in d { m[w, default: 0] += 1 }; return m }
var cinv: [String: [Int]] = [:]
for (i, t) in cdocToks.enumerated() { for w in Set(t) { cinv[w, default: []].append(i) } }
func cbm25(_ q: String, skip: Int) -> [(Int, Double)] {
  let k1 = 1.2, b = 0.75
  var acc: [Int: Double] = [:]
  for w in Set(tok(q)) {
    guard let post = cinv[w], let d = cdf[w] else { continue }
    let idf = log(1 + (cN - Double(d) + 0.5) / (Double(d) + 0.5))
    for i in post where i != skip {
      let f = Double(ctf[i][w] ?? 0), dl = Double(cdocToks[i].count)
      acc[i, default: 0] += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * dl / cavgdl))
    }
  }
  return acc.map { ($0.key, $0.value) }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
}
// ---- P2′: the same BM25, but with the shipped `files` column present (weights text 1.0 / files 0.1).
// The weight only bounds how much a path MATCH contributes. The effect that needs measuring is the
// other one: FTS5 normalises by the row's TOTAL token count across all columns, so every commit row
// got longer and its `text` matches are discounted relative to nodes and loose ends. Modelling only
// the weight would measure nothing, so `dl` here is the sum of both fields' token counts and `df`
// counts a row as containing a term if it appears in EITHER column — as FTS5 does.
let cFileToks = ckept.map { tok($0.files) }
let cftf: [[String: Int]] = cFileToks.map { d in var m: [String: Int] = [:]; for w in d { m[w, default: 0] += 1 }; return m }
let cCombinedLen = (0..<ckept.count).map { Double(cdocToks[$0].count + cFileToks[$0].count) }
let cAvgCombined = cCombinedLen.reduce(0, +) / cN
var cfdf: [String: Int] = [:]
for i in 0..<ckept.count { for w in Set(cdocToks[i]).union(Set(cFileToks[i])) { cfdf[w, default: 0] += 1 } }
var cfinv: [String: [Int]] = [:]
for i in 0..<ckept.count { for w in Set(cdocToks[i]).union(Set(cFileToks[i])) { cfinv[w, default: []].append(i) } }

func cbm25WithFiles(_ q: String, skip: Int) -> [(Int, Double)] {
  let k1 = 1.2, b = 0.75, filesWeight = 0.1
  var acc: [Int: Double] = [:]
  for w in Set(tok(q)) {
    guard let post = cfinv[w], let d = cfdf[w] else { continue }
    let idf = log(1 + (cN - Double(d) + 0.5) / (Double(d) + 0.5))
    for i in post where i != skip {
      let norm = k1 * (1 - b + b * cCombinedLen[i] / cAvgCombined)
      func saturate(_ f: Double) -> Double { f == 0 ? 0 : (f * (k1 + 1)) / (f + norm) }
      acc[i, default: 0] += idf * (saturate(Double(ctf[i][w] ?? 0))
                                   + filesWeight * saturate(Double(cftf[i][w] ?? 0)))
    }
  }
  return acc.map { ($0.key, $0.value) }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
}

func cvrank(_ q: String, skip: Int) -> [(Int, Double)] {
  guard let qv = embed(q) else { return [] }
  return (0..<cvecs.count).filter { $0 != skip }.map { ($0, cosf(qv, cvecs[$0])) }.sorted { $0.1 > $1.1 }
}

print("\n== gibberish + negatives AFTER hygiene (vector) ==")
for q in ["banana zeppelin custard velocipede", "sourdough starter hydration ratio"] {
  let r = cvrank(q, skip: -1).prefix(3)
  print("  Q: \(q)")
  for (i, s) in r { print(String(format: "    %.3f ", s) + "[\(ckept[i].kind)] " + ckept[i].text.replacingOccurrences(of: "\n", with: " ").prefix(66)) }
}

// (the query count is printed below, after `cq` is drawn — it is env-configurable)
var cByNode: [String: [Int]] = [:]
for (i, d) in ckept.enumerated() { cByNode[d.nodeID, default: []].append(i) }
let cEligible = cByNode.filter { $0.value.count >= 4 && $0.value.count <= 200 }
var g2: UInt64 = 7
func rnd2(_ n: Int) -> Int { g2 = g2 &* 6364136223846793005 &+ 1442695040888963407; return Int((g2 >> 33) % UInt64(n)) }
let cKeys = cEligible.keys.sorted()
// n=300 is the committed default so runs stay comparable to the recorded baselines. Raise it via
// PENSIEVE_MEASURE_N only to resolve a difference that is ambiguous at 300 (see the McNemar block).
let queryCount = Int(ProcessInfo.processInfo.environment["PENSIEVE_MEASURE_N"] ?? "") ?? 300
var cq: [Int] = []
let eligibleTotal = cEligible.values.reduce(0) { $0 + $1.count }
while cq.count < min(queryCount, eligibleTotal) {
  let nk = cKeys[rnd2(cKeys.count)]
  let cands = cEligible[nk]!
  let pick = cands[rnd2(cands.count)]
  if !cq.contains(pick) { cq.append(pick) }
}
print("\n== same-node relatedness on the CLEANED corpus (n=\(cq.count)) ==")
func cEval(_ label: String, _ ranker: (Int) -> [(Int, Double)]) {
  var p1 = 0.0, p5 = 0.0, mrr = 0.0
  for q in cq {
    let gold = Set(cByNode[ckept[q].nodeID]!).subtracting([q])
    let r = ranker(q)
    if let f = r.first, gold.contains(f.0) { p1 += 1 }
    p5 += Double(r.prefix(5).filter { gold.contains($0.0) }.count) / 5.0
    if let pos = r.prefix(50).firstIndex(where: { gold.contains($0.0) }) { mrr += 1 / Double(pos + 1) }
  }
  let n = Double(cq.count)
  print(label.padding(toLength: 10, withPad: " ", startingAt: 0) + String(format: "P@1=%.3f  P@5=%.3f  MRR@50=%.3f", p1/n, p5/n, mrr/n))
}
cEval("vector", { cvrank(ckept[$0].text, skip: $0) })
// `bm25` is BOTH the post-P1 baseline and — after the verification gate rejected the shared table —
// the SHIPPED P2′ ranking: paths live in their own FTS5 table, so they no longer lengthen the text
// row. `bm25+files` is the REJECTED configuration, kept so the rejection stays reproducible.
cEval("bm25", { cbm25(ckept[$0].text, skip: $0) })
cEval("bm25+files", { cbm25WithFiles(ckept[$0].text, skip: $0) })

// The two BM25 rows are PAIRED (identical corpus, identical 300 queries), so the difference between
// two point estimates is not the question — the discordant pairs are. McNemar's exact test over the
// queries where exactly one configuration got P@1 right is what decides whether the verification
// gate's "P@1 regressed" precondition is actually met, or whether it is sampling noise.
var onlyBaselineRight = 0, onlyFilesRight = 0
for q in cq {
  let gold = Set(cByNode[ckept[q].nodeID]!).subtracting([q])
  let baselineRight = cbm25(ckept[q].text, skip: q).first.map { gold.contains($0.0) } ?? false
  let filesRight = cbm25WithFiles(ckept[q].text, skip: q).first.map { gold.contains($0.0) } ?? false
  if baselineRight && !filesRight { onlyBaselineRight += 1 }
  if filesRight && !baselineRight { onlyFilesRight += 1 }
}
let discordant = onlyBaselineRight + onlyFilesRight
// Two-sided exact binomial p over the discordant pairs (p = 0.5 under the null).
func logFactorial(_ n: Int) -> Double { (1...max(n, 1)).reduce(0.0) { $0 + log(Double($1)) } }
func binomialProbability(_ k: Int, _ n: Int) -> Double {
  exp(logFactorial(n) - logFactorial(k) - logFactorial(n - k) - Double(n) * log(2))
}
let observed = min(onlyBaselineRight, onlyFilesRight)
var pValue = 0.0
if discordant > 0 { for k in 0...observed { pValue += 2 * binomialProbability(k, discordant) } }
print(String(format: "McNemar: baseline-only-right=%d  files-only-right=%d  (n=%d)  p=%.3f",
             onlyBaselineRight, onlyFilesRight, discordant, min(pValue, 1.0)))
