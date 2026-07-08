import Foundation
import Testing
@testable import PensieveKit

// NOTE: `Fixtures/salience-labels.json` is a SYNTHETIC STARTER (10 invented example quotes,
// not sampled from any real store) — it exists only so this harness compiles and is runnable.
// The real go/no-go requires replacing it with ~100-150 hand-labeled quotes sampled from the
// live store. See `Fixtures/salience-labels.README.md` and `.superpowers/sdd/task-A5-brief.md`.

private struct Labeled: Codable { let quote: String; let salient: Bool }

/// Review-time eval against the REAL on-device model. Skipped in CI (no deterministic gate for a
/// probabilistic model). Run: PENSIEVE_SALIENCE_EVAL=1 ./scripts/test.sh --filter salienceEval
@Test func salienceEvalReport() async throws {
  guard ProcessInfo.processInfo.environment["PENSIEVE_SALIENCE_EVAL"] == "1" else { return }
  let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Fixtures/salience-labels.json")
  let labels = try JSONDecoder().decode([Labeled].self, from: Data(contentsOf: url))
  let provider = makeDefaultLLMProvider()
  let ends = labels.map { VerifiedLooseEnd(text: $0.quote, quote: $0.quote, role: "user", sourceMessageIndex: 0) }
  let msgs = labels.enumerated().map { TranscriptMessage(index: $0.offset, role: "user", text: $0.element.quote, timestamp: nil, isUserPrompt: true) }
  // (sourceMessageIndex is 0 for all here; give each end its own index if you want per-item context.)
  let kept = Set(await SalienceClassifier(provider: provider).filter(ends, messages: msgs).map(\.quote))

  let salientLabels = labels.filter { $0.salient }
  let keptSalient = salientLabels.filter { kept.contains($0.quote) }.count
  let keptTotal = labels.filter { kept.contains($0.quote) }.count
  let recall = Double(keptSalient) / Double(max(1, salientLabels.count))
  let precision = Double(keptSalient) / Double(max(1, keptTotal))
  print("SALIENCE EVAL — precision=\(precision) recall=\(recall) kept=\(keptTotal)/\(labels.count)")
}
