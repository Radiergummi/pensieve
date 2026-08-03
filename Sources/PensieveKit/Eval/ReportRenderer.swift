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
  public static func markdown(_ scorecard: Scorecard) -> String {
    var out = "# Pensieve LLM Eval Scorecard\n\n"
    out += "Corpus: `\(scorecard.corpusHash)` — recommendation valid for work resembling this corpus; "
    out += "re-sample if your workload shifts.\n\n"
    out += "> Caveats: `$/run` is an **estimate** (chars/4 tokens × config price; judge cost excluded). "
    out += "Latency is **not like-for-like** (on-device is hardware-bound local compute + multiple calls; "
    out += "cloud is a network round-trip).\n\n"
    for taskScorecard in scorecard.tasks {
      out += "## \(taskScorecard.task)\n\n"
      if let agreement = taskScorecard.judgeAgreement {
        out += "Judge-vs-human agreement: **\(String(format: "%.0f%%", agreement * 100))**\n\n"
      }
      out += "| model | quality | precision | recall | $/run (est) | p50 latency | fab? |\n|---|---|---|---|---|---|---|\n"
      for cellScore in taskScorecard.cells {
        func f(_ doubleValue: Double?) -> String { doubleValue.map { String(format: "%.2f", $0) } ?? "—" }
        let modelName = cellScore.modelLabel + (cellScore.isOnDevice ? " (local)" : "")
        let costText = String(format: "%.4f", cellScore.costUSD)
        let fabricationMark = cellScore.reproducedFabrication ? "⚠︎" : ""
        out += "| \(modelName) | \(f(cellScore.quality)) | \(f(cellScore.precision)) | \(f(cellScore.recall)) | "
        out += "$\(costText) | \(Int(cellScore.latencyP50))ms | \(fabricationMark) |\n"
      }
      out += "\n**Recommended: \(taskScorecard.recommendation.winner)** — \(taskScorecard.recommendation.reason)\n\n"
    }
    return out
  }
}
