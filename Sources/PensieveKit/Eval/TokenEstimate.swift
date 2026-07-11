import Foundation

public enum TokenEstimate {
  public static func tokens(_ text: String) -> Int { Int(ceil(Double(text.count) / 4.0)) }
  public static func costUSD(inputText: String, outputText: String, spec: ModelSpec) -> Double {
    let inTok = Double(tokens(inputText)), outTok = Double(tokens(outputText))
    return inTok / 1_000_000 * spec.inputPricePerM + outTok / 1_000_000 * spec.outputPricePerM
  }
}
