// Adversarial re-measurement of the retrieval eval spec, on the REAL corpus.
// Reproduces NLContextualEmbedder (per-token -> mean-pool -> unit-normalize) exactly.
import Foundation
import NaturalLanguage

let SP = ProcessInfo.processInfo.environment["PENSIEVE_MEASURE_DIR"] ?? FileManager.default.currentDirectoryPath
let docLimit = ProcessInfo.processInfo.environment["DOC_LIMIT"].flatMap { Int($0) } ?? Int.max
let provLimit = ProcessInfo.processInfo.environment["PROV_LIMIT"].flatMap { Int($0) } ?? 120

struct Doc { let kind: String; let itemID: String; let nodeID: String; let text: String }

func loadJSONL(_ path: String) -> [[String: String]] {
  guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
  var out: [[String: String]] = []
  for line in s.split(separator: "\n") {
    guard let d = line.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
    out.append(o.compactMapValues { $0 as? String })
  }
  return out
}

var docs = loadJSONL("\(SP)/corpus.jsonl").compactMap { o -> Doc? in
  guard let k = o["kind"], let i = o["itemID"], let n = o["nodeID"], let t = o["text"], !t.isEmpty
  else { return nil }
  return Doc(kind: k, itemID: i, nodeID: n, text: t)
}
if docs.count > docLimit { docs = Array(docs.prefix(docLimit)) }
FileHandle.standardError.write("docs: \(docs.count)\n".data(using: .utf8)!)

// ---------- embedding (exact copy of the shipped pipeline) ----------
guard let model = NLContextualEmbedding(script: .latin) else { fatalError("no model") }
if !model.hasAvailableAssets { fatalError("assets missing") }
try model.load()

func embed(_ text: String) -> [Float]? {
  guard let r = try? model.embeddingResult(for: text, language: nil) else { return nil }
  var toks: [[Float]] = []
  r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in
    toks.append(v.map { Float($0) }); return true
  }
  guard !toks.isEmpty else { return nil }
  let dim = toks[0].count
  var m = [Float](repeating: 0, count: dim)
  for t in toks { for i in 0..<dim { m[i] += t[i] } }
  let inv = 1 / Float(toks.count)
  for i in 0..<dim { m[i] *= inv }
  var norm: Float = 0; for v in m { norm += v * v }
  norm = norm.squareRoot()
  guard norm > 0 else { return nil }
  return m.map { $0 / norm }
}
func cos(_ a: [Float], _ b: [Float]) -> Double {
  var s: Float = 0; for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }; return Double(s)
}
func renorm(_ v: [Float]) -> [Float] {
  var n: Float = 0; for x in v { n += x * x }; n = n.squareRoot()
  return n > 0 ? v.map { $0 / n } : v
}

let t0 = Date()
var vecs: [[Float]] = []; var kept: [Doc] = []
for (i, d) in docs.enumerated() {
  if let v = embed(d.text) { vecs.append(v); kept.append(d) }
  if i % 500 == 0 { FileHandle.standardError.write("  embedded \(i)\n".data(using: .utf8)!) }
}
let embedSecs = Date().timeIntervalSince(t0)
print("== embedding ==")
print("embedded \(kept.count)/\(docs.count) docs in \(String(format: "%.1f", embedSecs))s  dim=\(vecs.first?.count ?? 0)")

// mean-centred variant (the backlog's proposed remedy)
let dim = vecs[0].count
var mean = [Float](repeating: 0, count: dim)
for v in vecs { for i in 0..<dim { mean[i] += v[i] } }
for i in 0..<dim { mean[i] /= Float(vecs.count) }
let centred = vecs.map { v in renorm((0..<dim).map { v[$0] - mean[$0] }) }

// ---------- anisotropy on the REAL corpus ----------
var g: UInt64 = 42
func rnd(_ n: Int) -> Int { g = g &* 6364136223846793005 &+ 1442695040888963407; return Int((g >> 33) % UInt64(n)) }
var raws: [Double] = [], cens: [Double] = []
for _ in 0..<4000 {
  let a = rnd(kept.count), b = rnd(kept.count)
  guard a != b, kept[a].nodeID != kept[b].nodeID else { continue }   // different projects => unrelated
  raws.append(cos(vecs[a], vecs[b])); cens.append(cos(centred[a], centred[b]))
}
func stats(_ x: [Double]) -> String {
  let s = x.sorted()
  return String(format: "n=%d min=%.4f p25=%.4f mean=%.4f p75=%.4f max=%.4f",
                s.count, s[0], s[s.count/4], x.reduce(0,+)/Double(x.count), s[3*s.count/4], s[s.count-1])
}
print("\n== anisotropy (cross-node doc pairs, REAL corpus) ==")
print("raw      \(stats(raws))")
print("centred  \(stats(cens))")

// ---------- lexical: BM25 over the same corpus ----------
func tok(_ s: String) -> [String] {
  s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
}
let docToks = kept.map { tok($0.text) }
var df: [String: Int] = [:]
for t in docToks { for w in Set(t) { df[w, default: 0] += 1 } }
let N = Double(kept.count)
let avgdl = Double(docToks.reduce(0) { $0 + $1.count }) / N
var tf: [[String: Int]] = docToks.map { d in var m: [String: Int] = [:]; for w in d { m[w, default: 0] += 1 }; return m }
func bm25(_ q: String) -> [(Int, Double)] {
  let k1 = 1.2, b = 0.75
  let qt = Set(tok(q))
  var out: [(Int, Double)] = []
  for i in 0..<kept.count {
    var s = 0.0
    let dl = Double(docToks[i].count)
    for w in qt {
      guard let f = tf[i][w], let d = df[w] else { continue }
      let idf = log(1 + (N - Double(d) + 0.5) / (Double(d) + 0.5))
      s += idf * (Double(f) * (k1 + 1)) / (Double(f) + k1 * (1 - b + b * dl / avgdl))
    }
    if s > 0 { out.append((i, s)) }
  }
  return out.sorted { $0.1 > $1.1 }
}
func vecRank(_ q: String, _ space: [[Float]], centring: Bool) -> [(Int, Double)] {
  guard var qv = embed(q) else { return [] }
  if centring { qv = renorm((0..<dim).map { qv[$0] - mean[$0] }) }
  return (0..<space.count).map { ($0, cos(qv, space[$0])) }.sorted { $0.1 > $1.1 }
}

// ---------- the four real backlog queries + negatives ----------
let probes = [
  "German localization String Catalog",
  "sqlite-vec vendored C target",
  "background sync agent login items",
  "focus mode filtering work vs personal",
  "how do I stop the commit hook from slowing me down",
  "banana zeppelin custard velocipede",
  "sourdough starter hydration ratio",
]
print("\n== top-3 by strategy (real corpus) ==")
for q in probes {
  print("\nQ: \(q)")
  for (name, ranked) in [("vector", vecRank(q, vecs, centring: false)),
                         ("centred", vecRank(q, centred, centring: true)),
                         ("bm25", bm25(q))] {
    let top = ranked.prefix(3).map { (i, s) in
      "\(String(format: "%.3f", s)) [\(kept[i].kind)] \(kept[i].text.replacingOccurrences(of: "\n", with: " ").prefix(64))"
    }
    print("  \(name.padding(toLength: 8, withPad: " ", startingAt: 0))\(top.joined(separator: "\n          "))")
  }
}

// ---------- the spec's provenance gold set, actually scored ----------
struct Pair { let q: String; let goldItemID: String }
let pairs: [Pair] = loadJSONL("\(SP)/prov_pairs.jsonl").compactMap {
  guard let q = $0["q"], let g = $0["gold"] else { return nil }; return Pair(q: q, goldItemID: g)
}
let idIndex = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($0.element.itemID, $0.offset) })
var scored = pairs.filter { idIndex[$0.goldItemID] != nil }
if scored.count > provLimit { scored = Array(scored.prefix(provLimit)) }
print("\n== provenance stratum, scored on the real corpus (n=\(scored.count)) ==")

func evalGold(_ ranker: (String) -> [(Int, Double)], _ label: String) {
  var r1 = 0, r5 = 0, r10 = 0, mrrSum = 0.0
  var goldScores: [Double] = []
  for p in scored {
    let gi = idIndex[p.goldItemID]!
    let ranked = ranker(p.q)
    if let pos = ranked.firstIndex(where: { $0.0 == gi }) {
      let rank = pos + 1
      if rank <= 1 { r1 += 1 }; if rank <= 5 { r5 += 1 }; if rank <= 10 { r10 += 1 }
      if rank <= 10 { mrrSum += 1.0 / Double(rank) }
      goldScores.append(ranked[pos].1)
    }
  }
  let n = Double(scored.count)
  let pad = label.padding(toLength: 9, withPad: " ", startingAt: 0)
  print(pad + String(format: "recall@1=%.3f recall@5=%.3f recall@10=%.3f MRR@10=%.3f",
                     Double(r1)/n, Double(r5)/n, Double(r10)/n, mrrSum/n))
}
evalGold({ vecRank($0, vecs, centring: false) }, "vector")
evalGold({ vecRank($0, centred, centring: true) }, "centred")
evalGold({ bm25($0) }, "bm25")

// ---------- separation, per strategy, on the real corpus ----------
let negatives = ["banana zeppelin custard velocipede", "florp glimberty wunkle quazzit",
                 "sourdough starter hydration ratio", "flight change fee refund policy"]
print("\n== negatives: top-1 score per strategy vs gold-hit score distribution ==")
for (name, ranker) in [("vector", { (q: String) in vecRank(q, vecs, centring: false) }),
                       ("centred", { (q: String) in vecRank(q, centred, centring: true) }),
                       ("bm25", { (q: String) in bm25(q) })] {
  let negTop = negatives.compactMap { ranker($0).first?.1 }
  var golds: [Double] = []
  for p in scored.prefix(60) {
    let gi = idIndex[p.goldItemID]!
    if let hit = ranker(p.q).first(where: { $0.0 == gi }) { golds.append(hit.1) }
  }
  let gs = golds.sorted()
  // AUC: P(gold score > negative top score)
  var wins = 0.0, total = 0.0
  for gv in golds { for nv in negTop { total += 1; if gv > nv { wins += 1 } else if gv == nv { wins += 0.5 } } }
  let pad = name.padding(toLength: 8, withPad: " ", startingAt: 0)
  let negStr = negTop.map { String(format: "%.3f", $0) }.joined(separator: ", ")
  print(pad + "negTop=[" + negStr + "]  " + String(format: "goldHit p10=%.4f median=%.4f  AUC(gold>negTop)=%.3f",
               gs.isEmpty ? 0 : gs[gs.count/10], gs.isEmpty ? 0 : gs[gs.count/2],
               total > 0 ? wins/total : -1))
}

// ---------- idf tie structure: does "top-quartile idf" mean anything? ----------
print("\n== leakage-guard feasibility: idf distribution over the real corpus ==")
let dfs = df.values.sorted()
let types = df.count
let hapax = df.values.filter { $0 == 1 }.count
let df2orless = df.values.filter { $0 <= 2 }.count
print("distinct token types: \(types)")
print("types appearing in exactly 1 doc (max idf, all tied): \(hapax) = \(String(format: "%.1f", 100*Double(hapax)/Double(types)))%")
print("types appearing in <=2 docs: \(df2orless) = \(String(format: "%.1f", 100*Double(df2orless)/Double(types)))%")
print("df at the 25th percentile of types (i.e. the 'top-quartile idf' cut): df=\(dfs[types/4])")
print("=> a df cut inside the hapax tie block is decided by tie-breaking, not by rarity")
