import Foundation

public enum TokenEstimate {
  public static func tokens(_ text: String) -> Int { Int(ceil(Double(text.count) / 4.0)) }

  /// Takes token COUNTS, not texts. The prompts a cell actually sent are built inside the production
  /// path being measured and are not available to the scorer, so they are counted at the provider
  /// seam (`MeasuredProvider`) and carried on the sample. Passing `inputText: ""` — as the scorer did
  /// before — priced every model as if its prompt were free.
  public static func costUSD(inputTokens: Int, outputTokens: Int, spec: ModelSpec) -> Double {
    Double(inputTokens) / 1_000_000 * spec.inputPricePerM
      + Double(outputTokens) / 1_000_000 * spec.outputPricePerM
  }

  public static func costUSD(inputText: String, outputText: String, spec: ModelSpec) -> Double {
    costUSD(inputTokens: tokens(inputText), outputTokens: tokens(outputText), spec: spec)
  }
}
