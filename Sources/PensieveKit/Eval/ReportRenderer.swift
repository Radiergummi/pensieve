import Foundation

public struct Scorecard: Codable, Sendable {
  public var corpusHash: String
  public var tasks: [TaskScorecard]
  public init(corpusHash: String, tasks: [TaskScorecard]) { self.corpusHash = corpusHash; self.tasks = tasks }
}
public struct TaskScorecard: Codable, Sendable {
  public var task: String
  public var cells: [CellScore]
  public var recommendation: Recommendation
  public var judgeAgreement: Double?
  public init(task: String, cells: [CellScore], recommendation: Recommendation, judgeAgreement: Double?) {
    self.task = task; self.cells = cells; self.recommendation = recommendation; self.judgeAgreement = judgeAgreement
  }
}

public enum ReportRenderer {
  public static func markdown(_ s: Scorecard) -> String {
    var out = "# Pensieve LLM Eval Scorecard\n\n"
    out += "Corpus: `\(s.corpusHash)` — recommendation valid for work resembling this corpus; re-sample if your workload shifts.\n\n"
    out += "> Caveats: `$/run` is an **estimate** (chars/4 tokens × config price; judge cost excluded). "
    out += "Latency is **not like-for-like** (on-device is hardware-bound local compute + multiple calls; cloud is a network round-trip).\n\n"
    for t in s.tasks {
      out += "## \(t.task)\n\n"
      if let a = t.judgeAgreement { out += "Judge-vs-human agreement: **\(String(format: "%.0f%%", a * 100))**\n\n" }
      out += "| model | quality | precision | recall | $/run (est) | p50 latency | fab? |\n|---|---|---|---|---|---|---|\n"
      for c in t.cells {
        func f(_ d: Double?) -> String { d.map { String(format: "%.2f", $0) } ?? "—" }
        out += "| \(c.modelLabel)\(c.isOnDevice ? " (local)" : "") | \(f(c.quality)) | \(f(c.precision)) | \(f(c.recall)) | $\(String(format: "%.4f", c.costUSD)) | \(Int(c.latencyP50))ms | \(c.reproducedFabrication ? "⚠︎" : "") |\n"
      }
      out += "\n**Recommended: \(t.recommendation.winner)** — \(t.recommendation.reason)\n\n"
    }
    return out
  }
}
