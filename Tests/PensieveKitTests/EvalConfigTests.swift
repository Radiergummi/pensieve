import Testing
import Foundation
@testable import PensieveKit

@Test func evalConfigDecodesRosterAndBars() throws {
  let json = """
  {
    "referenceProvider": "apple/foundation-models",
    "corpusSize": 30, "corpusSeed": 42, "noiseMargin": 0.03,
    "judge": {"label":"anthropic/opus","kind":"cloud","flavor":"anthropic","baseURL":"https://api.anthropic.com","model":"claude-opus-4-8","inputPricePerM":15,"outputPricePerM":75},
    "roster": [
      {"label":"apple/foundation-models","kind":"foundationModels","inputPricePerM":0,"outputPricePerM":0},
      {"label":"openai/gpt-5-nano","kind":"cloud","flavor":"openAICompatible","baseURL":"https://api.openai.com/v1","model":"gpt-5-nano","inputPricePerM":0.05,"outputPricePerM":0.4}
    ],
    "bars": [
      {"task":"extraction","inheritFromIncumbent":true},
      {"task":"narration","inheritFromIncumbent":true}
    ]
  }
  """
  let url = tempURL("eval-config", ext: "json")
  try json.data(using: .utf8)!.write(to: url)
  let cfg = try EvalConfig.load(from: url)
  #expect(cfg.roster.count == 2)
  #expect(cfg.referenceProvider == "apple/foundation-models")
  #expect(cfg.roster[0].inputPricePerM == 0)
  #expect(cfg.bar(for: "extraction")?.inheritFromIncumbent == true)
  #expect(cfg.bar(for: "missing") == nil)
}
