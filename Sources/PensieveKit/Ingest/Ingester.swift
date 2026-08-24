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

/// A strand materialized while ingesting one spool row, still carrying its branch name. `drain`
/// collects these and names them itself, so the LLM round-trips are capped per PASS rather than
/// being one-per-row — see `Ingester.strandNameCap`.
struct BornStrand {
  let id: UUID
  let branchKey: String
}

/// What ingesting one spool row produced.
struct RowIngestOutcome {
  let eventCount: Int
  let bornStrand: BornStrand?

  init(eventCount: Int, bornStrand: BornStrand? = nil) {
    self.eventCount = eventCount
    self.bornStrand = bornStrand
  }

  /// A row that produced nothing — a dropped unknown kind, or a deliberately retired capture.
  static let nothing = RowIngestOutcome(eventCount: 0)
}

public struct Ingester: Sendable {
  let spool: CaptureSpool
  let database: any DatabaseWriter
  let resolver: ProjectResolver
  let llm: (any LLMProvider)?

  public init(spool: CaptureSpool, database: any DatabaseWriter, llm: (any LLMProvider)? = nil) {
    self.spool = spool; self.database = database; self.resolver = ProjectResolver(database: database); self.llm = llm
  }

  /// Retry window for a `cc.session` row whose transcript is absent (it may not be written yet).
  static let absentTranscriptGracePeriod: TimeInterval = 24 * 60 * 60

  /// Per-drain cap on strand-naming LLM round-trips — sibling of `nameRefineCap` /
  /// `descriptionRefineCap`, for their reason: `nameStrand` runs inside `drain()`, so uncapped it
  /// lets one pass (a flush-and-reingest, or a backlog after the agent was down) stall the sync
  /// cycle on N sequential model calls.
  ///
  /// Unlike its siblings this cap is NOT monotonic across passes: a strand past it keeps its branch
  /// name, and no marker makes a later pass retry it. Accepted cost — a branch name is a serviceable
  /// label and the alternative is an unbounded pass — but a real limitation, not a free one.
  static let strandNameCap = 20

  /// Non-async wrappers so `database.write`/`database.read` resolve to GRDB's synchronous overload even
  /// when called from an `async` context (`ingest`/`nameStrand`) — a bare trailing closure
  /// there is ambiguous with GRDB's `async` `write`/`read` overloads and triggers spurious
  /// Sendable diagnostics.
  /// Internal rather than private: the LLM-assist passes in `Ingester+Naming.swift` use them too.
  func writeSync<T>(_ updates: (Database) throws -> T) throws -> T { try database.write(updates) }
  func readSync<T>(_ value: (Database) throws -> T) throws -> T { try database.read(value) }

  /// Drains all pending spool rows. Returns the number of canonical events CREATED
  /// (not rows processed — a dropped unknown-kind row counts 0).
  ///
  /// A row that fails is now CLASSIFIED rather than logged identically whatever went wrong: a
  /// permanently-unusable row (an undecodable payload) says so explicitly and names itself, while a
  /// transient one says it will retry. Both stay pending — see the catch block for why a permanent
  /// failure is still not consumed. Successful and dropped rows are marked per-row so progress is
  /// durable even if a later row fails.
  @discardableResult
  public func drain() async throws -> Int {
    let rows = try spool.pending()
    Log.ingest.info("Drain start: \(rows.count, privacy: .public) pending rows")
    var created = 0
    var strandNamings = 0
    for row in rows {
      do {
        let outcome = try ingest(row)
        try spool.markIngested([row.id])
        created += outcome.eventCount
        Log.ingest.debug("""
          Ingested row \(row.id, privacy: .public) kind=\(row.kind, privacy: .public) \
          events=\(outcome.eventCount, privacy: .public)
          """)
        if let born = outcome.bornStrand {
          guard strandNamings < Self.strandNameCap else { continue }
          strandNamings += 1
          await nameStrand(born.id, branchKey: born.branchKey)
        }
      } catch let error as IngestError where error.isPermanent {
        // Named as permanent, but deliberately still left PENDING, for a non-local reason:
        // `StoreRelocator.recoverPendingRows` infers "rows may still be stranded in the old spool"
        // from `pendingCount() != 0` and refuses to recycle the old folder on that basis. Marking
        // this row ingested would make a relocation report a clean migration and then delete the
        // folder still holding the only copy of it. "Stop re-attempting" and "nothing is stranded"
        // are two different facts, and the spool can currently store only one of them.
        Log.ingest.error("""
          Spool row \(row.id, privacy: .public) kind=\(row.kind, privacy: .public) is PERMANENTLY \
          unusable and cannot succeed on retry — remove it from the spool: \
          \(error, privacy: .public) payload=\(row.payload, privacy: .private)
          """)
        continue
      } catch {
        Log.ingest.error("Spool row \(row.id, privacy: .public) failed, will retry: \(error, privacy: .public)")
        continue   // leave unmarked; retry next drain
      }
    }
    Log.ingest.info("Drain complete: \(created, privacy: .public) events created")
    return created
  }

  private func ingest(_ row: SpoolRow) throws -> RowIngestOutcome {
    let data = Data(row.payload.utf8)
    switch row.kind {
    case CaptureKind.gitCommit:
      return try ingestGitCommit(data: data, row: row)

    case CaptureKind.gitCheckout:
      return try ingestGitCheckout(data: data, row: row)

    case CaptureKind.ccSession:
      return try ingestSession(data: data, row: row)

    case CaptureKind.ccSessionStart:
      return try ingestSessionStart(data: data, row: row)

    default:
      return .nothing   // unknown kind: dropped (still marked ingested by drain), 0 events
    }
  }

  /// Decodes a spool payload, turning any decoding failure into a PERMANENT `IngestError`. The
  /// spooled text never changes, so a payload that does not decode now cannot decode later; without
  /// this, one malformed row was re-attempted on every drain, forever, logging the same line.
  private func decodePayload<Payload: Decodable>(_ type: Payload.Type, from data: Data,
                                                 kind: String) throws -> Payload {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw IngestError.undecodablePayload(kind: kind, reason: String(describing: error))
    }
  }
}

extension Ingester {
  private func ingestGitCommit(data: Data, row: SpoolRow) throws -> RowIngestOutcome {
    let payload = try decodePayload(GitCommitPayload.self, from: data, kind: row.kind)
    let key = try Self.identityKey(forHookPath: payload.repoPath, capturedCommonDir: payload.commonDir)
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
    let born = outcome.born.map { BornStrand(id: $0, branchKey: branchKey ?? "") }
    return RowIngestOutcome(eventCount: outcome.inserted ? 1 : 0, bornStrand: born)
  }

  private func ingestGitCheckout(data: Data, row: SpoolRow) throws -> RowIngestOutcome {
    let payload = try decodePayload(GitCheckoutPayload.self, from: data, kind: row.kind)
    let key = try Self.identityKey(forHookPath: payload.repoPath, capturedCommonDir: payload.commonDir)
    let detail = try encodeJSON(["from": payload.fromRef, "to": payload.toRef, "branch": payload.branch])
    let inserted = try writeSync { database -> Bool in
      let (project, source) = try resolver.resolve(database, path: key, kind: SourceKind.gitRepo)
      // Fingerprint off the same canonical `key` the source is keyed on, not the raw `repoPath`:
      // with the raw path, one checkout captured from two spellings of one directory (a symlinked
      // worktree, `/tmp` vs `/private/tmp`) produced two fingerprints and dedup missed.
      return try insertIfNew(database, Event(nodeID: project.id, sourceID: source.id, occurredAt: row.timestamp,
            kind: CaptureKind.gitCheckout, summary: "checkout \(payload.branch)", detailJSON: detail,
            fingerprint: Fingerprint.checkout(repo: key, from: payload.fromRef, to: payload.toRef, branch: payload.branch)))
    }
    return RowIngestOutcome(eventCount: inserted ? 1 : 0)
  }

  private func ingestSession(data: Data, row: SpoolRow) throws -> RowIngestOutcome {
    let payload = try decodePayload(SessionRefPayload.self, from: data, kind: row.kind)
    let transcriptURL = URL(fileURLWithPath: payload.transcriptPath)
    let session = TranscriptParser.parse(fileURL: transcriptURL)
    // No cwd → can't attribute. Transient vs permanent, because retiring is permanent and
    // discovery's per-cycle re-spool must not loop forever. Retried inside the grace period when the
    // transcript is absent/0-byte (it may still fill) or could not be READ at all (a permissions
    // blip, or bytes that are not UTF-8). One that read fine and simply carries no cwd never will → drop.
    guard let cwd = session.cwd else {
      let size = (try? transcriptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      guard size == 0 || !session.wasReadable else { return .nothing }
      guard row.timestamp > Date().addingTimeInterval(-Self.absentTranscriptGracePeriod) else { return .nothing }
      throw IngestError.unattributableSession
    }
    // Attribute to the git repo ROOT (matching how commits are keyed), not the raw cwd,
    // so a session launched from a subdirectory lands in the same project as its commits.
    // A non-git cwd is legitimate here — unlike the git kinds — so the raw-path fallback stays.
    let key = ProjectResolver.identityKey(forRepoPath: cwd) ?? ProjectResolver.canonical(cwd)
    // A degenerate root is not an area of work, and never becomes one — so dropping is permanent
    // (return → the drain marks the row ingested) rather than retrying forever.
    guard !ProjectResolver.isDegenerateRoot(key) else {
      Log.ingest.info("Dropped session with degenerate cwd \(key, privacy: .public) — not an area of work")
      return .nothing
    }
    let detail = try encodeJSON(["sessionID": session.sessionID,
                                 "prompts": String(session.userPromptCount),
                                 "transcriptPath": payload.transcriptPath])
    // Resolved BEFORE the write transaction: `Git.defaultBranch` shells out to up to four `git`
    // subprocesses, and holding the canonical write lock across process spawns blocks every other
    // writer for as long as git takes to answer.
    let branchKey = sessionBranchKey(forSessionID: session.sessionID)
    let outcome = try writeSync { database -> SessionIngestOutcome in
      let (project, source) = try resolver.resolve(database, path: key, kind: SourceKind.claudeCode)
      let fingerprint = Fingerprint.session(sessionID: session.sessionID)
      // A duplicate event is NOT a no-op: the `SessionEnd` hook re-spools the same session as it
      // grows, so one sessionID arrives repeatedly with more messages each time (`discover` skips
      // sessions that already have an event, so it is not the trigger). The event dedupes; the
      // passages must be rewritten from the now-longer transcript.
      if let existing = try existingEvent(database, sourceID: source.id, fingerprint: fingerprint) {
        try writePassages(database, session: session, nodeID: existing.nodeID,
                          eventID: existing.id, fallbackDate: row.timestamp)
        return SessionIngestOutcome(inserted: false, born: nil, branch: nil)
      }
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
    let born = outcome.born.map { BornStrand(id: $0, branchKey: outcome.branch ?? "") }
    return RowIngestOutcome(eventCount: outcome.inserted ? 1 : 0, bornStrand: born)
  }

  /// The branch a session launched on, from the `cc.session.start` sidecar, as a strand key.
  /// Reads and resolves entirely outside any write transaction — see the call site.
  private func sessionBranchKey(forSessionID sessionID: String) -> String? {
    let sidecar: SessionBranch? = (try? readSync { database in
      try SessionBranch.where { $0.sessionID.eq(sessionID) }.fetchOne(database)
    }) ?? nil
    guard let sidecar, let raw = sidecar.branch else { return nil }
    return Git.strandBranchKey(branch: raw, defaultBranch: Git.defaultBranch(in: sidecar.commonDir))
  }

  private func ingestSessionStart(data: Data, row: SpoolRow) throws -> RowIngestOutcome {
    let payload = try decodePayload(SessionStartPayload.self, from: data, kind: row.kind)
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
    return .nothing
  }

  /// Whether an event with this (sourceID, fingerprint) already exists — the dedup predicate,
  /// shared by `insertIfNew` and the git.commit/cc.session branches that dedup before extra work.
  /// Derived from `existingEvent` so the predicate itself has exactly one definition.
  private func eventExists(_ database: Database, sourceID: UUID, fingerprint: String?) throws -> Bool {
    try existingEvent(database, sourceID: sourceID, fingerprint: fingerprint) != nil
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
      // Passages of those events must follow too: `passage.nodeID` is what retrieval and the
      // search corpus both read, so a passage left behind names the wrong node in every surface.
      try Passage.where { $0.eventID.eq(eventID) }
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
