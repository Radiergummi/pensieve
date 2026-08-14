import Foundation
import SQLiteData
import GRDB
import os

/// Outcome of the `cc.session` write transaction. A named type instead of a tuple purely to
/// satisfy `large_tuple` — same three members, same meaning.
private struct SessionIngestOutcome {
  let inserted: Bool
  let born: UUID?
  let branch: String?
}

/// `git show` output for a commit. A named type instead of a tuple purely to satisfy
/// `large_tuple` — same three members, same meaning.
private struct CommitFields {
  let subject: String
  let when: Date
  let files: String
}

public struct Ingester: Sendable {
  let spool: CaptureSpool
  let database: any DatabaseWriter
  let resolver: ProjectResolver
  let llm: (any LLMProvider)?

  public init(spool: CaptureSpool, database: any DatabaseWriter, llm: (any LLMProvider)? = nil) {
    self.spool = spool; self.database = database; self.resolver = ProjectResolver(database: database); self.llm = llm
  }

  enum IngestError: Error { case unattributableSession }

  /// Retry window for a `cc.session` row whose transcript is absent (it may not be written yet).
  static let absentTranscriptGracePeriod: TimeInterval = 24 * 60 * 60

  /// Non-async wrappers so `database.write`/`database.read` resolve to GRDB's synchronous overload even
  /// when called from an `async` context (`ingest`/`nameStrand`) — a bare trailing closure
  /// there is ambiguous with GRDB's `async` `write`/`read` overloads and triggers spurious
  /// Sendable diagnostics.
  private func writeSync<T>(_ updates: (Database) throws -> T) throws -> T { try database.write(updates) }
  private func readSync<T>(_ value: (Database) throws -> T) throws -> T { try database.read(value) }

  /// Drains all pending spool rows. Returns the number of canonical events CREATED
  /// (not rows processed — a dropped unknown-kind row counts 0). A row that throws is
  /// left unmarked so it retries next drain; successful and dropped rows are marked
  /// ingested per-row so progress is durable even if a later row fails.
  @discardableResult
  public func drain() async throws -> Int {
    let rows = try spool.pending()
    Log.ingest.info("Drain start: \(rows.count, privacy: .public) pending rows")
    var created = 0
    for row in rows {
      do {
        let eventCount = try await ingest(row)
        try spool.markIngested([row.id])
        created += eventCount
        Log.ingest.debug("Ingested row \(row.id, privacy: .public) kind=\(row.kind, privacy: .public) events=\(eventCount, privacy: .public)")
      } catch {
        Log.ingest.error("Spool row \(row.id, privacy: .public) failed: \(error, privacy: .public)")
        continue   // leave unmarked; retry next drain
      }
    }
    Log.ingest.info("Drain complete: \(created, privacy: .public) events created")
    return created
  }

  /// Returns the number of events created (0 for a dropped unknown kind).
  private func ingest(_ row: SpoolRow) async throws -> Int {
    let data = Data(row.payload.utf8)
    switch row.kind {
    case CaptureKind.gitCommit:
      return try await ingestGitCommit(data: data, row: row)

    case CaptureKind.gitCheckout:
      return try ingestGitCheckout(data: data, row: row)

    case CaptureKind.ccSession:
      return try await ingestSession(data: data, row: row)

    case CaptureKind.ccSessionStart:
      return try ingestSessionStart(data: data)

    default:
      return 0   // unknown kind: dropped (still marked ingested by drain), 0 events
    }
  }
}

extension Ingester {
  private func ingestGitCommit(data: Data, row: SpoolRow) async throws -> Int {
    let payload = try JSONDecoder().decode(GitCommitPayload.self, from: data)
    let key = Git.commonDir(in: payload.repoPath) ?? ProjectResolver.canonical(payload.repoPath)
    let branchKey = Git.strandBranchKey(branch: payload.branch, defaultBranch: Git.defaultBranch(in: payload.repoPath))
    let fields = gitCommitFields(hash: payload.hash, repo: payload.repoPath, fallbackTime: row.timestamp)
    let detail = try encodeJSON(["hash": payload.hash, "branch": payload.branch, "files": fields.files])
    let outcome = try writeSync { database -> (inserted: Bool, born: UUID?) in
      let (project, source) = try resolver.resolve(database, path: key, kind: SourceKind.gitRepo)
      let dup = try eventExists(database, sourceID: source.id, fingerprint: Fingerprint.commit(hash: payload.hash))
      if dup { return (false, nil) }
      let attr = try attributeToNode(database, projectNodeID: project.id, branchKey: branchKey, kind: CaptureKind.gitCommit)
      try Event.insert {
        Event(nodeID: attr.nodeID, sourceID: source.id, occurredAt: fields.when,
              kind: CaptureKind.gitCommit, summary: fields.subject, detailJSON: detail,
              fingerprint: Fingerprint.commit(hash: payload.hash), branchKey: branchKey)
      }.execute(database)
      try resurfaceIfArchived(database, nodeID: attr.nodeID)
      return (true, attr.bornStrand)
    }
    if let born = outcome.born { await nameStrand(born, branchKey: branchKey ?? "") }
    return outcome.inserted ? 1 : 0
  }

  private func ingestGitCheckout(data: Data, row: SpoolRow) throws -> Int {
    let payload = try JSONDecoder().decode(GitCheckoutPayload.self, from: data)
    let key = Git.commonDir(in: payload.repoPath) ?? ProjectResolver.canonical(payload.repoPath)
    let detail = try encodeJSON(["from": payload.fromRef, "to": payload.toRef, "branch": payload.branch])
    let inserted = try writeSync { database -> Bool in
      let (project, source) = try resolver.resolve(database, path: key, kind: SourceKind.gitRepo)
      return try insertIfNew(database, Event(nodeID: project.id, sourceID: source.id, occurredAt: row.timestamp,
            kind: CaptureKind.gitCheckout, summary: "checkout \(payload.branch)", detailJSON: detail,
            fingerprint: Fingerprint.checkout(repo: payload.repoPath, from: payload.fromRef, to: payload.toRef, branch: payload.branch)))
    }
    return inserted ? 1 : 0
  }

  private func ingestSession(data: Data, row: SpoolRow) async throws -> Int {
    let payload = try JSONDecoder().decode(SessionRefPayload.self, from: data)
    let transcriptURL = URL(fileURLWithPath: payload.transcriptPath)
    let session = TranscriptParser.parse(fileURL: transcriptURL)
    // No cwd → can't attribute. Distinguish transient from permanent so discovery's per-cycle
    // re-spool can't loop forever: an empty/absent transcript may still fill (throw → stays
    // pending) but only inside the grace period, past which it is gone for good and re-parsing
    // it every drain is waste; a non-empty one with no cwd never will (drop → 0 events).
    guard let cwd = session.cwd else {
      let size = (try? transcriptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      if size == 0 {
        guard row.timestamp > Date().addingTimeInterval(-Self.absentTranscriptGracePeriod) else { return 0 }
        throw IngestError.unattributableSession
      }
      return 0
    }
    // Attribute to the git repo ROOT (matching how commits are keyed), not the raw cwd,
    // so a session launched from a subdirectory lands in the same project as its commits.
    let key = Git.commonDir(in: cwd) ?? ProjectResolver.canonical(cwd)
    // A degenerate root is not an area of work. Dropping it here is permanent (return 0 → the
    // drain marks the row ingested) exactly like the non-empty-transcript-without-cwd case
    // above: such a session will never become attributable, so retrying it forever is worse.
    guard !ProjectResolver.isDegenerateRoot(key) else {
      Log.ingest.info("Dropped session with degenerate cwd \(key, privacy: .public) — not an area of work")
      return 0
    }
    let detail = try encodeJSON(["sessionID": session.sessionID,
                                 "prompts": String(session.userPromptCount),
                                 "transcriptPath": payload.transcriptPath])
    let outcome = try writeSync { database -> SessionIngestOutcome in
      let (project, source) = try resolver.resolve(database, path: key, kind: SourceKind.claudeCode)
      let fingerprint = Fingerprint.session(sessionID: session.sessionID)
      // A duplicate event is NOT a no-op: `TranscriptDiscovery` re-spools in-progress sessions as
      // they grow, so the same sessionID arrives repeatedly with more messages each time. The event
      // dedupes; the passages must be rewritten from the now-longer transcript.
      if let existing = try existingEvent(database, sourceID: source.id, fingerprint: fingerprint) {
        try writePassages(database, session: session, nodeID: existing.nodeID,
                          eventID: existing.id, fallbackDate: row.timestamp)
        return SessionIngestOutcome(inserted: false, born: nil, branch: nil)
      }
      let branchKey: String? = {
        guard let sessionBranch = try? SessionBranch.where({ $0.sessionID.eq(session.sessionID) }).fetchOne(database),
              let raw = sessionBranch.branch else { return nil }
        return Git.strandBranchKey(branch: raw, defaultBranch: Git.defaultBranch(in: sessionBranch.commonDir))
      }()
      let attr = try attributeToNode(database, projectNodeID: project.id, branchKey: branchKey, kind: CaptureKind.ccSession)
      let event = Event(nodeID: attr.nodeID, sourceID: source.id,
                        occurredAt: session.endedAt ?? row.timestamp,
                        kind: CaptureKind.ccSession,
                        summary: "session (\(session.userPromptCount) prompts)",
                        detailJSON: detail, fingerprint: fingerprint, branchKey: branchKey)
      try Event.insert { event }.execute(database)
      try writePassages(database, session: session, nodeID: attr.nodeID, eventID: event.id,
                        fallbackDate: row.timestamp)
      try resurfaceIfArchived(database, nodeID: attr.nodeID)
      return SessionIngestOutcome(inserted: true, born: attr.bornStrand, branch: branchKey)
    }
    if let born = outcome.born { await nameStrand(born, branchKey: outcome.branch ?? "") }
    return outcome.inserted ? 1 : 0
  }

  private func ingestSessionStart(data: Data) throws -> Int {
    let payload = try JSONDecoder().decode(SessionStartPayload.self, from: data)
    try writeSync { database in
      let exists = try SessionBranch.where { $0.sessionID.eq(payload.sessionID) }.fetchOne(database) != nil
      if !exists {
        try SessionBranch.insert {
          SessionBranch(sessionID: payload.sessionID,
                        branch: payload.branch.isEmpty ? nil : payload.branch,
                        commonDir: payload.commonDir)
        }.execute(database)
      }
    }
    return 0
  }

  /// Whether an event with this (sourceID, fingerprint) already exists — the dedup predicate,
  /// shared by `insertIfNew` and the git.commit/cc.session branches that dedup before extra work.
  private func eventExists(_ database: Database, sourceID: UUID, fingerprint: String?) throws -> Bool {
    try Event.where { $0.sourceID.eq(sourceID) && $0.fingerprint.eq(fingerprint) }.fetchCount(database) > 0
  }

  /// Inserts the event only if no event with the same (sourceID, fingerprint) exists.
  /// Returns whether an insert actually happened (false when deduped).
  private func insertIfNew(_ database: Database, _ event: Event) throws -> Bool {
    if try eventExists(database, sourceID: event.sourceID, fingerprint: event.fingerprint) { return false }
    try Event.insert { event }.execute(database)
    return true
  }

  /// Decides the node an event belongs to, materializing a strand when a branch crosses the
  /// ≥2-same-kind-events threshold. Runs inside the write transaction. Returns the nodeID to
  /// stamp on the event, plus the id of a strand *born on this call* (for post-transaction
  /// naming) or nil.
  private func attributeToNode(_ database: Database, projectNodeID: UUID,
                               branchKey: String?, kind: String)
    throws -> (nodeID: UUID, bornStrand: UUID?) {
    guard let branchKey else { return (projectNodeID, nil) }

    if let strand = try Node
      .where({ $0.parentID.eq(projectNodeID) && $0.branchKey.eq(branchKey) && $0.kind.eq(NodeKind.strand) })
      .fetchOne(database) {
      return (strand.id, nil)                          // strand already exists → attribute directly
    }

    // Count same-kind events already tagged with this branch at the project node.
    let sameKind = try Event
      .where { $0.nodeID.eq(projectNodeID) && $0.branchKey.eq(branchKey) && $0.kind.eq(kind) }
      .fetchCount(database)
    guard sameKind + 1 >= 2 else { return (projectNodeID, nil) }   // not yet — stay tagged

    let strand = Node(name: branchKey, parentID: projectNodeID, kind: NodeKind.strand, branchKey: branchKey)
    try Node.insert { strand }.execute(database)
    let repointedEventIDs = try Event.where { $0.nodeID.eq(projectNodeID) && $0.branchKey.eq(branchKey) }
      .fetchAll(database).map(\.id)
    try Event.where { $0.nodeID.eq(projectNodeID) && $0.branchKey.eq(branchKey) }
      .update { $0.nodeID = strand.id }.execute(database)   // repoint every tagged event (all kinds)
    // Loose ends already extracted from those events (by a prior drain) live on the project
    // node too — repoint them so LooseEndQueries.open(nodeID: strand) doesn't miss them.
    for eventID in repointedEventIDs {
      try LooseEnd.where { $0.sourceEventID.eq(eventID) }
        .update { $0.nodeID = strand.id }.execute(database)
    }
    return (strand.id, strand.id)
  }

  /// After attributing an event, bring an archived node (and its ancestor chain) back to
  /// "active" so it reappears in place. Muted nodes are sticky and left untouched. Runs inside
  /// the write transaction that inserted the event.
  private func resurfaceIfArchived(_ database: Database, nodeID: UUID) throws {
    let chain = try [nodeID] + NodeCommands.ancestorIDs(database, of: nodeID)
    try NodeCommands.resurface(database, ids: chain)
  }

  /// Per-pass cap so a big first run (or a flush-and-reingest) can't stall the sync cycle on N
  /// sequential model calls. The `nameInferred` marker makes the remainder monotonic across passes.
  static let nameRefineCap = 20

  /// Per-pass cap on actual LLM description calls (a `.noSignal` candidate is free and does NOT
  /// consume a slot), so a batch of signal-less repos can't stall the sync cycle.
  static let descriptionRefineCap = 20

  /// True when `metadataJSON` already carries the "naming attempted" marker.
  static func nameInferred(inMetadata json: String) -> Bool {
    let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    return (obj?["nameInferred"] as? Bool) ?? false
  }

  /// Returns `metadataJSON` with the "naming attempted" marker set, preserving other keys.
  static func settingNameInferred(in json: String) -> String {
    var obj = ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:]
    obj["nameInferred"] = true
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
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
    for candidate in candidates.prefix(Self.nameRefineCap) {
      let ctx = ProjectContext.gather(commonDir: candidate.commonDir)
      let raw = try? await llm.complete(prompt: ProjectContext.namePrompt(ctx))
      let firstLine = raw?.split(separator: "\n", omittingEmptySubsequences: true)
        .first.map(String.init) ?? ""
      let name = TextQuality.sanitizeLabel(firstLine)
      let newMeta = Self.settingNameInferred(in: candidate.metadataJSON)
      try? writeSync { database in
        if let name {
          try Node.where { $0.id.eq(candidate.id) }
            .update { $0.name = name; $0.metadataJSON = newMeta }.execute(database)
        } else {
          try Node.where { $0.id.eq(candidate.id) }
            .update { $0.metadataJSON = newMeta }.execute(database)
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
  private func nameStrand(_ strandID: UUID, branchKey: String) async {
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
    let desc = lines.count > 1 ? lines[1] : ""
    try? writeSync { database in
      try Node.where { $0.id.eq(strandID) }.update { $0.name = name; $0.description = desc }.execute(database)
    }
    Log.ingest.info("Strand named: \(name, privacy: .public) (id=\(strandID, privacy: .public))")
  }

  /// One `git show` yields subject, ISO-8601 commit date, and the changed-file list.
  private func gitCommitFields(hash: String, repo: String, fallbackTime: Date) -> CommitFields {
    let raw = Git.run(["show", "--name-only", "--format=%s%n%cI", hash], in: repo) ?? ""
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let subject = lines.first.flatMap { $0.isEmpty ? nil : $0 } ?? hash
    let when = (lines.count > 1 ? ISO8601DateFormatter().date(from: lines[1]) : nil) ?? fallbackTime
    let files = lines.dropFirst(2).filter { !$0.isEmpty }.joined(separator: "\n")
    return CommitFields(subject: subject, when: when, files: files)
  }
}
