import Foundation
import Testing
@testable import PensieveKit

// NOTE: `Fixtures/salience-labels.json` is a SYNTHETIC STARTER (10 invented example quotes,
// not sampled from any real store) — it exists only so this harness compiles and is runnable.
// The real go/no-go requires replacing it with ~100-150 hand-labeled quotes sampled from the
// live store. See `Fixtures/salience-labels.README.md` and `.superpowers/sdd/task-A5-brief.md`.

private struct Labeled: Codable { let quote: String; let salient: Bool }

/// Review-time eval against the REAL on-device model. Skipped in CI (no deterministic gate for a
/// probabilistic model). Run: PENSIEVE_SALIENCE_EVAL=1 make test FILTER=salienceEval
@Test func salienceEvalReport() async throws {
  guard ProcessInfo.processInfo.environment["PENSIEVE_SALIENCE_EVAL"] == "1" else { return }
  // Fixture path is overridable so a real go/no-go can point at a private out-of-repo file of
  // real quotes (PENSIEVE_SALIENCE_LABELS) without committing provenance data; defaults to the
  // synthetic starter fixture in-repo.
  let url = ProcessInfo.processInfo.environment["PENSIEVE_SALIENCE_LABELS"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/salience-labels.json")
  let labels = try JSONDecoder().decode([Labeled].self, from: Data(contentsOf: url))
  // Provider is selectable so the go/no-go can escalate from on-device to `claude -p` (plan A5
  // step 3) without editing code: PENSIEVE_SALIENCE_EVAL_PROVIDER=claude uses the CLI provider,
  // pinned to a cheap model via PENSIEVE_CLAUDE_MODEL (default Haiku). Default = on-device.
  let provider: any LLMProvider
  if ProcessInfo.processInfo.environment["PENSIEVE_SALIENCE_EVAL_PROVIDER"] == "claude" {
    let model = ProcessInfo.processInfo.environment["PENSIEVE_CLAUDE_MODEL"] ?? "claude-haiku-4-5-20251001"
    // The shared provider, so this eval spawns `claude -p` with the same cwd pin production uses —
    // an unpinned child becomes a captured Claude Code session in whatever directory ran the tests.
    provider = ClaudeCLIProvider(model: model)
  } else {
    provider = makeDefaultLLMProvider()
  }
  let ends = labels.map { VerifiedLooseEnd(text: $0.quote, quote: $0.quote, role: "user", sourceMessageIndex: 0) }
  let msgs = labels.enumerated().map {
    TranscriptMessage(index: $0.offset, role: "user", text: $0.element.quote, timestamp: nil, isUserPrompt: true)
  }
  // (sourceMessageIndex is 0 for all here; give each end its own index if you want per-item context.)
  let kept = Set(await SalienceClassifier(provider: provider).filter(ends, messages: msgs).map(\.quote))

  let salientLabels = labels.filter { $0.salient }
  let keptSalient = salientLabels.filter { kept.contains($0.quote) }.count
  let keptTotal = labels.filter { kept.contains($0.quote) }.count
  let recall = Double(keptSalient) / Double(max(1, salientLabels.count))
  let precision = Double(keptSalient) / Double(max(1, keptTotal))
  print("SALIENCE EVAL — precision=\(precision) recall=\(recall) kept=\(keptTotal)/\(labels.count)")
  // The DROP list is the primary go/no-go signal on unlabeled real quotes: every dropped item
  // must be genuinely an in-the-moment request, never deferred/parked/decision work.
  let dropped = labels.map(\.quote).filter { !kept.contains($0) }
  print("SALIENCE EVAL — dropped \(dropped.count)/\(labels.count):")
  for quote in dropped { print("  DROP: \(quote)") }
}
