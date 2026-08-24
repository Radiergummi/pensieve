import Foundation
import SQLiteData
import GRDB
import os

/// The Ingester's three LLM-assist passes, split out of `Ingester.swift`.
///
/// They are the only part of the Ingester that is not spool-draining: each takes already-ingested
/// rows and asks a model for an *organizational label* — a project name, a project description, a
/// strand name. All three sit deliberately OUTSIDE the verbatim trust gate (a label is not a
/// surfaced claim about your work), all three are best-effort and non-fatal, and all three are
/// no-ops when no provider is configured, which is how the app's LLM-less drain skips them.
///
/// Every pass is capped, and the caps exist for one reason: these run inside (or right beside) the
/// drain, so an uncapped pass lets a single cycle make N sequential model calls and stall background
/// ingestion. See `Ingester.strandNameCap` for the third cap, which `drain` itself enforces.
extension Ingester {
  /// Per-pass cap so a big first run (or a flush-and-reingest) can't stall the sync cycle on N
  /// sequential model calls. The `nameInferred` marker makes the remainder monotonic across passes.
  static var nameRefineCap: Int { 20 }

  /// Per-pass cap on actual LLM description calls (a `.noSignal` candidate is free and does NOT
  /// consume a slot), so a batch of signal-less repos can't stall the sync cycle.
  static var descriptionRefineCap: Int { 20 }

  /// True when `metadataJSON` already carries the "naming attempted" marker.
  static func nameInferred(inMetadata json: String) -> Bool {
    let metadata = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    return (metadata?["nameInferred"] as? Bool) ?? false
  }

  /// Returns `metadataJSON` with the "naming attempted" marker set, preserving other keys.
  static func settingNameInferred(in json: String) -> String {
    var metadata = ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:]
    metadata["nameInferred"] = true
    guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    else { return json }
    return String(bytes: data, encoding: .utf8) ?? json
  }

  /// Best-effort, once-per-node display-name inference for git project nodes. Selects untouched,
  /// single-`gitRepo` project nodes (name still == verbatim default, not already marked), infers
  /// a name on-device from local repo signals, and writes it — always stamping the marker so each
  /// node is attempted exactly once. Non-fatal and outside the trust gate (organizational label),
  /// exactly like `nameStrand`. A no-op when no provider is configured (e.g. the app's drain).
  func refineProjectNames() async {
    guard let llm else { return }

    struct Candidate { let id: UUID; let commonDir: String; let metadataJSON: String }
    let candidates: [Candidate] = (try? readSync { database -> [Candidate] in
      let projects = try Node.where { $0.kind.eq(NodeKind.project) }.fetchAll(database)
      var out: [Candidate] = []
      for node in projects {
        if Self.nameInferred(inMetadata: node.metadataJSON) { continue }
        guard let key = try NodeDescriber.soleGitRepoKey(database, nodeID: node.id) else { continue }
        guard node.name == ProjectResolver.displayName(forKey: key) else { continue }
        out.append(Candidate(id: node.id, commonDir: key, metadataJSON: node.metadataJSON))
      }
      return out
    }) ?? []

    Log.ingest.info("Refining project names: \(candidates.count, privacy: .public) candidates")
    // The cap bounds real LLM calls, not candidates — matching `describeProjectNodes`, so a run of
    // signal-less repos cannot exhaust the budget without asking the model anything.
    var invocations = 0
    for candidate in candidates {
      if invocations >= Self.nameRefineCap { break }
      let context = ProjectContext.gather(commonDir: candidate.commonDir)
      // The same gate `NodeDescriber.describe` applies to the same input, and for the same reason:
      // with only a directory name to go on, the model has nothing to infer FROM and instead
      // invents a plausible expansion — which is how `wt-550` became "Weight Transfer Tool" and
      // `web-trace-570` became "Web Trace Viewer 570" in the live store. A skipped node is
      // deliberately NOT marked, so it is retried once the repo grows a README or a manifest.
      guard ProjectContext.hasMeaningfulSignal(context) else { continue }
      invocations += 1
      let raw = try? await llm.complete(prompt: ProjectContext.namePrompt(context))
      let firstLine = raw?.split(separator: "\n", omittingEmptySubsequences: true)
        .first.map(String.init) ?? ""
      let name = TextQuality.sanitizeLabel(firstLine)
      let newMetadata = Self.settingNameInferred(in: candidate.metadataJSON)
      try? writeSync { database in
        if let name {
          try Node.where { $0.id.eq(candidate.id) }
            .update { $0.name = name; $0.metadataJSON = newMetadata }.execute(database)
        } else {
          try Node.where { $0.id.eq(candidate.id) }
            .update { $0.metadataJSON = newMetadata }.execute(database)
        }
      }
    }
  }

  /// Best-effort description pass for git project nodes. Selects `project` nodes with exactly one
  /// `gitRepo` source and an EMPTY description (the empty field is the retry condition — no marker),
  /// and fills them via `NodeDescriber`. The cap bounds real LLM calls, not candidates: a
  /// `.noSignal` result (thin/absent README) is free and leaves the node to retry once real content
  /// appears. No-op when no provider is configured (e.g. the app's LLM-less drain). Runs from
  /// `SyncRunner`, outside the trust gate — like `refineProjectNames`.
  func describeProjectNodes() async {
    guard let llm else { return }

    let candidates: [UUID] = (try? readSync { database -> [UUID] in
      let projects = try Node.where { $0.kind.eq(NodeKind.project) }.fetchAll(database)
      var out: [UUID] = []
      for node in projects where node.description.isEmpty {
        if try NodeDescriber.soleGitRepoKey(database, nodeID: node.id) != nil { out.append(node.id) }
      }
      return out
    }) ?? []

    Log.ingest.info("Describing project nodes: \(candidates.count, privacy: .public) candidates")
    var invocations = 0
    for id in candidates {
      if invocations >= Self.descriptionRefineCap { break }
      let outcome = await NodeDescriber.describe(database, nodeID: id, provider: llm, force: false)
      if outcome == .wrote || outcome == .attemptedEmpty { invocations += 1 }
    }
  }

  /// Names/describes a freshly materialized strand from its accumulated activity. Non-fatal:
  /// any failure leaves the branch-name + empty description. Organizational label, not a
  /// surfaced claim — outside the verbatim gate by design.
  ///
  /// Called from `drain()`, which enforces `strandNameCap` across the whole pass.
  func nameStrand(_ strandID: UUID, branchKey: String) async {
    guard let llm else { return }
    let summaries: [String] = (try? readSync { database in
      try Event.where { $0.nodeID.eq(strandID) }
        .order { $0.occurredAt.desc() }.limit(20).fetchAll(database).map(\.summary)
    }) ?? []
    guard !summaries.isEmpty else { return }
    let prompt = """
    Below is recent activity on a branch of work called "\(branchKey)". In 3-6 words on line 1, \
    give it a human-readable name — a plain label, not numbered or bulleted, no trailing period. \
    On line 2, one sentence describing it. Do not invent facts beyond the activity shown.

    \(summaries.joined(separator: "\n"))
    """
    guard let out = try? await llm.complete(prompt: prompt) else { return }
    let lines = out.split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let first = lines.first, let name = TextQuality.sanitizeLabel(first) else { return }
    let description = lines.count > 1 ? lines[1] : ""
    try? writeSync { database in
      try Node.where { $0.id.eq(strandID) }.update { $0.name = name; $0.description = description }.execute(database)
    }
    Log.ingest.info("Strand named: \(name, privacy: .public) (id=\(strandID, privacy: .public))")
  }
}
