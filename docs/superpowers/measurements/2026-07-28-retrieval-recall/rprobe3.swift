// Part 2: a large-n, LLM-free, non-circular gold set the spec never considered —
// "same-node relatedness" (exactly what ⌘F "Related" is for), plus hybrid RRF.
import Foundation
import NaturalLanguage

let SP = ProcessInfo.processInfo.environment["PENSIEVE_MEASURE_DIR"] ?? FileManager.default.currentDirectoryPath
struct Doc { let kind: String; let itemID: String; let nodeID: String; let text: String }

var docs: [Doc] = []
if let s = try? String(contentsOfFile: "\(SP)/corpus.jsonl", encoding: .utf8) {
  for line in s.split(separator: "\n") {
    guard let d = line.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let k = o["kind"] as? String, let i = o["itemID"] as? String,
          let n = o["nodeID"] as? String, let t = o["text"] as? String, !t.isEmpty else { continue }
    docs.append(Doc(kind: k, itemID: i, nodeID: n, text: t))
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

// Hand-written low-lexical-overlap paraphrase queries: the case semantic search exists FOR.
let paraphrases = [
  "how do I keep saving my work from slowing down when I type a commit",
  "the thing that stops the computer asking permission again after each rebuild",
  "making the conversation log easier to read",
  "remembering where I left off on each thing I'm building",
  "finding old work when I can't remember the words I used",
  "letting the assistant see my past work automatically",
  "hiding finished projects without losing them",
  "keeping work and personal things apart",
]
for q in paraphrases {
  print("\nQ: \(q)")
  for (name, r) in [("vector", vrank(q, vecs, centring: false, skip: -1)),
                    ("bm25", bm25(q, skip: -1))] {
    let lines = r.prefix(3).map { (i, s) in
      String(format: "%.3f ", s) + "[\(kept[i].kind)] "
        + kept[i].text.replacingOccurrences(of: "\n", with: " ").prefix(72)
    }
    print("  " + name.padding(toLength: 8, withPad: " ", startingAt: 0)
          + (lines.isEmpty ? "(no results)" : lines.joined(separator: "\n          ")))
  }
}
