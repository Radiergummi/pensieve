import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// NOT a test — a guarded generator for the retrieval measurement probes, which need the real
/// corpus as JSONL and must get it from `EmbeddableCorpus.gather` verbatim (a hand-rolled SQL
/// mirror would reintroduce exactly the eval/production divergence reusing `gather` prevents).
///
/// No-ops unless BOTH env vars are set, so it never runs in CI or an ordinary suite run:
///   PENSIEVE_MEASURE_DIR   destination directory for corpus.jsonl
///   PENSIEVE_MEASURE_DB    a VACUUM INTO snapshot of the canonical store (NOT the live file:
///                          it is WAL-mode, and a plain copy silently drops uncheckpointed rows)
///
/// Usage:
///   sqlite3 ~/Library/Application\ Support/Pensieve/pensieve.sqlite \
///     "VACUUM INTO '/tmp/measure/snapshot.sqlite'"
///   PENSIEVE_MEASURE_DIR=/tmp/measure PENSIEVE_MEASURE_DB=/tmp/measure/snapshot.sqlite \
///     ./scripts/test.sh --filter dumpCorpusForMeasurement
///
/// The output is real work text. Delete it when the measurement run is done.
@Test func dumpCorpusForMeasurement() throws {
  let environment = ProcessInfo.processInfo.environment
  guard let directory = environment["PENSIEVE_MEASURE_DIR"],
        let snapshotPath = environment["PENSIEVE_MEASURE_DB"] else { return }

  let database = try openCanonicalDatabase(at: URL(fileURLWithPath: snapshotPath))
  let corpus = try EmbeddableCorpus.gather(database)

  var lines: [String] = []
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  for item in corpus {
    let record = ["kind": item.kind, "itemID": item.itemID, "nodeID": item.nodeID,
                  "state": item.state, "text": item.text, "files": item.files]
    lines.append(String(data: try encoder.encode(record), encoding: .utf8) ?? "")
  }
  let destination = URL(fileURLWithPath: directory).appendingPathComponent("corpus.jsonl")
  try lines.joined(separator: "\n").write(to: destination, atomically: true, encoding: .utf8)

  var counts: [String: Int] = [:]
  for item in corpus { counts[item.kind, default: 0] += 1 }
  print("corpus.jsonl written: \(corpus.count) items \(counts.sorted { $0.key < $1.key })")
}
