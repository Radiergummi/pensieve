import Foundation

public enum Agreement {
  /// Fraction of quotes where the judge's grounded flag matches the human's. nil if no shared quotes.
  public static func rate(judge: [CandidateLabel], human: [CandidateLabel]) -> Double? {
    let judgeMap = Dictionary(judge.map { ($0.quote, $0.grounded) }, uniquingKeysWith: { a, _ in a })
    let shared = human.filter { judgeMap[$0.quote] != nil }
    guard !shared.isEmpty else { return nil }
    let matches = shared.filter { judgeMap[$0.quote] == $0.grounded }.count
    return Double(matches) / Double(shared.count)
  }
}
