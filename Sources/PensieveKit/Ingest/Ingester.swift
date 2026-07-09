import Foundation
import SQLiteData
import GRDB
import os

public struct Ingester: Sendable {
  let spool: CaptureSpool
  let db: any DatabaseWriter
  let resolver: ProjectResolver
  let llm: (any LLMProvider)?

  public init(spool: CaptureSpool, db: any DatabaseWriter, llm: (any LLMProvider)? = nil) {
    self.spool = spool; self.db = db; self.resolver = ProjectResolver(db: db); self.llm = llm
  }

  enum IngestError: Error { case unattributableSession }

  /// Non-async wrappers so `db.write`/`db.read` resolve to GRDB's synchronous overload even
  /// when called from an `async` context (`ingest`/`nameStrand`) — a bare trailing closure
  /// there is ambiguous with GRDB's `async` `write`/`read` overloads and triggers spurious
  /// Sendable diagnostics.
  private func writeSync<T>(_ updates: (Database) throws -> T) throws -> T { try db.write(updates) }
  private func readSync<T>(_ value: (Database) throws -> T) throws -> T { try db.read(value) }

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
        let n = try await ingest(row)
        try spool.markIngested([row.id])
        created += n
        Log.ingest.debug("Ingested row \(row.id, privacy: .public) kind=\(row.kind, privacy: .public) events=\(n, privacy: .public)")
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
      let p = try JSONDecoder().decode(GitCommitPayload.self, from: data)
      let key = Git.commonDir(in: p.repoPath) ?? ProjectResolver.canonical(p.repoPath)
      let branchKey = Git.strandBranchKey(branch: p.branch, defaultBranch: Git.defaultBranch(in: p.repoPath))
      let fields = gitCommitFields(hash: p.hash, repo: p.repoPath, fallbackTime: row.ts)
      let detail = try encodeJSON(["hash": p.hash, "branch": p.branch, "files": fields.files])
      let outcome = try writeSync { db -> (inserted: Bool, born: UUID?) in
        let (project, source) = try resolver.resolve(db, path: key, kind: SourceKind.gitRepo)
        let dup = try eventExists(db, sourceID: source.id, fingerprint: Fingerprint.commit(hash: p.hash))
        if dup { return (false, nil) }
        let attr = try attributeToNode(db, projectNodeID: project.id, branchKey: branchKey, kind: CaptureKind.gitCommit)
        try Event.insert {
          Event(nodeID: attr.nodeID, sourceID: source.id, occurredAt: fields.when,
                kind: CaptureKind.gitCommit, summary: fields.subject, detailJSON: detail,
                fingerprint: Fingerprint.commit(hash: p.hash), branchKey: branchKey)
        }.execute(db)
        return (true, attr.bornStrand)
      }
      if let born = outcome.born { await nameStrand(born, branchKey: branchKey ?? "") }
      return outcome.inserted ? 1 : 0

    case CaptureKind.gitCheckout:
      let p = try JSONDecoder().decode(GitCheckoutPayload.self, from: data)
      let key = Git.commonDir(in: p.repoPath) ?? ProjectResolver.canonical(p.repoPath)
      let detail = try encodeJSON(["from": p.from, "to": p.to, "branch": p.branch])
      let inserted = try writeSync { db -> Bool in
        let (project, source) = try resolver.resolve(db, path: key, kind: SourceKind.gitRepo)
        return try insertIfNew(db, Event(nodeID: project.id, sourceID: source.id, occurredAt: row.ts,
              kind: CaptureKind.gitCheckout, summary: "checkout \(p.branch)", detailJSON: detail,
              fingerprint: Fingerprint.checkout(repo: p.repoPath, from: p.from, to: p.to, branch: p.branch)))
      }
      return inserted ? 1 : 0

    case CaptureKind.ccSession:
      let p = try JSONDecoder().decode(SessionRefPayload.self, from: data)
      let transcriptURL = URL(fileURLWithPath: p.transcriptPath)
      let session = TranscriptParser.parse(fileURL: transcriptURL)
      // No cwd → can't attribute. Distinguish transient from permanent so discovery's
      // per-cycle re-spool can't loop forever: an empty/unreadable transcript may still fill
      // later (throw → stays pending, retries next drain); a non-empty transcript that still
      // has no cwd is corrupt/foreign and will never attribute (drop → drain marks it
      // ingested, returning 0 events).
      guard let cwd = session.cwd else {
        let size = (try? transcriptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size == 0 { throw IngestError.unattributableSession }
        return 0
      }
      // Attribute to the git repo ROOT (matching how commits are keyed), not the raw cwd,
      // so a session launched from a subdirectory lands in the same project as its commits.
      let key = Git.commonDir(in: cwd) ?? ProjectResolver.canonical(cwd)
      let detail = try encodeJSON(["sessionID": session.sessionID,
                                   "prompts": String(session.userPromptCount),
                                   "transcriptPath": p.transcriptPath])
      let outcome = try writeSync { db -> (inserted: Bool, born: UUID?, branch: String?) in
        let (project, source) = try resolver.resolve(db, path: key, kind: SourceKind.claudeCode)
        let dup = try eventExists(db, sourceID: source.id, fingerprint: Fingerprint.session(sessionID: session.sessionID))
        if dup { return (false, nil, nil) }
        let branchKey: String? = {
          guard let sb = try? SessionBranch.where({ $0.sessionID.eq(session.sessionID) }).fetchOne(db),
                let raw = sb.branch else { return nil }
          return Git.strandBranchKey(branch: raw, defaultBranch: Git.defaultBranch(in: sb.commonDir))
        }()
        let attr = try attributeToNode(db, projectNodeID: project.id, branchKey: branchKey, kind: CaptureKind.ccSession)
        try Event.insert {
          Event(nodeID: attr.nodeID, sourceID: source.id, occurredAt: session.endedAt ?? row.ts,
                kind: CaptureKind.ccSession, summary: "session (\(session.userPromptCount) prompts)",
                detailJSON: detail, fingerprint: Fingerprint.session(sessionID: session.sessionID),
                branchKey: branchKey)
        }.execute(db)
        return (true, attr.bornStrand, branchKey)
      }
      if let born = outcome.born { await nameStrand(born, branchKey: outcome.branch ?? "") }
      return outcome.inserted ? 1 : 0

    case CaptureKind.ccSessionStart:
      let p = try JSONDecoder().decode(SessionStartPayload.self, from: data)
      try writeSync { db in
        let exists = try SessionBranch.where { $0.sessionID.eq(p.sessionID) }.fetchOne(db) != nil
        if !exists {
          try SessionBranch.insert {
            SessionBranch(sessionID: p.sessionID,
                          branch: p.branch.isEmpty ? nil : p.branch,
                          commonDir: p.commonDir)
          }.execute(db)
        }
      }
      return 0

    default:
      return 0   // unknown kind: dropped (still marked ingested by drain), 0 events
    }
  }

  /// Whether an event with this (sourceID, fingerprint) already exists — the dedup predicate,
  /// shared by `insertIfNew` and the git.commit/cc.session branches that dedup before extra work.
  private func eventExists(_ db: Database, sourceID: UUID, fingerprint: String?) throws -> Bool {
    try Event.where { $0.sourceID.eq(sourceID) && $0.fingerprint.eq(fingerprint) }.fetchCount(db) > 0
  }

  /// Inserts the event only if no event with the same (sourceID, fingerprint) exists.
  /// Returns whether an insert actually happened (false when deduped).
  private func insertIfNew(_ db: Database, _ event: Event) throws -> Bool {
    if try eventExists(db, sourceID: event.sourceID, fingerprint: event.fingerprint) { return false }
    try Event.insert { event }.execute(db)
    return true
  }

  /// Decides the node an event belongs to, materializing a strand when a branch crosses the
  /// ≥2-same-kind-events threshold. Runs inside the write transaction. Returns the nodeID to
  /// stamp on the event, plus the id of a strand *born on this call* (for post-transaction
  /// naming) or nil.
  private func attributeToNode(_ db: Database, projectNodeID: UUID,
                               branchKey: String?, kind: String)
    throws -> (nodeID: UUID, bornStrand: UUID?) {
    guard let branchKey else { return (projectNodeID, nil) }

    if let strand = try Node
      .where({ $0.parentID.eq(projectNodeID) && $0.branchKey.eq(branchKey) && $0.kind.eq(NodeKind.strand) })
      .fetchOne(db) {
      return (strand.id, nil)                          // strand already exists → attribute directly
    }

    // Count same-kind events already tagged with this branch at the project node.
    let sameKind = try Event
      .where { $0.nodeID.eq(projectNodeID) && $0.branchKey.eq(branchKey) && $0.kind.eq(kind) }
      .fetchCount(db)
    guard sameKind + 1 >= 2 else { return (projectNodeID, nil) }   // not yet — stay tagged

    let strand = Node(name: branchKey, parentID: projectNodeID, kind: NodeKind.strand, branchKey: branchKey)
    try Node.insert { strand }.execute(db)
    let repointedEventIDs = try Event.where { $0.nodeID.eq(projectNodeID) && $0.branchKey.eq(branchKey) }
      .fetchAll(db).map(\.id)
    try Event.where { $0.nodeID.eq(projectNodeID) && $0.branchKey.eq(branchKey) }
      .update { $0.nodeID = strand.id }.execute(db)   // repoint every tagged event (all kinds)
    // Loose ends already extracted from those events (by a prior drain) live on the project
    // node too — repoint them so LooseEndQueries.open(nodeID: strand) doesn't miss them.
    for eventID in repointedEventIDs {
      try LooseEnd.where { $0.sourceEventID.eq(eventID) }
        .update { $0.nodeID = strand.id }.execute(db)
    }
    return (strand.id, strand.id)
  }

  /// Cleans an on-device-proposed strand name into a terse organizational label: strips a
  /// leading list/enumeration marker ("1. ", "2) ", "- ", "* ", "• "), wrapping quotes or
  /// backticks, and trailing sentence punctuation. Returns nil for empty input so the caller
  /// keeps the branch-key fallback name. Deterministic — the namer is outside the trust gate,
  /// but its output still shouldn't read like a numbered list item or a full sentence.
  static func sanitizeStrandName(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let marker = s.range(of: #"^(\d+[.)]|[-*•])\s+"#, options: .regularExpression) {
      s.removeSubrange(marker)
    }
    s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
    s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
    s = s.trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? nil : s
  }

  /// Per-pass cap so a big first run (or a flush-and-reingest) can't stall the sync cycle on N
  /// sequential model calls. The `nameInferred` marker makes the remainder monotonic across passes.
  static let nameRefineCap = 20

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
    return String(decoding: data, as: UTF8.self)
  }

  /// Best-effort, once-per-node display-name inference for git project nodes. Selects untouched,
  /// single-`gitRepo` project nodes (name still == verbatim default, not already marked), infers
  /// a name on-device from local repo signals, and writes it — always stamping the marker so each
  /// node is attempted exactly once. Non-fatal and outside the trust gate (organizational label),
  /// exactly like `nameStrand`. A no-op when no provider is configured (e.g. the app's drain).
  func refineProjectNames() async {
    guard let llm else { return }

    struct Candidate { let id: UUID; let commonDir: String; let metadataJSON: String }
    let candidates: [Candidate] = (try? readSync { db -> [Candidate] in
      let projects = try Node.where { $0.kind.eq(NodeKind.project) }.fetchAll(db)
      var out: [Candidate] = []
      for node in projects {
        if Self.nameInferred(inMetadata: node.metadataJSON) { continue }
        let gitSources = try Source
          .where { $0.nodeID.eq(node.id) && $0.kind.eq(SourceKind.gitRepo) }.fetchAll(db)
        guard gitSources.count == 1, let key = gitSources.first?.key else { continue }
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
      let name = Self.sanitizeStrandName(firstLine)
      let newMeta = Self.settingNameInferred(in: candidate.metadataJSON)
      try? writeSync { db in
        if let name {
          try Node.where { $0.id.eq(candidate.id) }
            .update { $0.name = name; $0.metadataJSON = newMeta }.execute(db)
        } else {
          try Node.where { $0.id.eq(candidate.id) }
            .update { $0.metadataJSON = newMeta }.execute(db)
        }
      }
    }
  }

  /// Names/describes a freshly materialized strand from its accumulated activity. Non-fatal:
  /// any failure leaves the branch-name + empty description. Organizational label, not a
  /// surfaced claim — outside the verbatim gate by design.
  private func nameStrand(_ strandID: UUID, branchKey: String) async {
    guard let llm else { return }
    let summaries: [String] = (try? readSync { db in
      try Event.where { $0.nodeID.eq(strandID) }
        .order { $0.occurredAt.desc() }.limit(20).fetchAll(db).map(\.summary)
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
    guard let first = lines.first, let name = Self.sanitizeStrandName(first) else { return }
    let desc = lines.count > 1 ? lines[1] : ""
    try? writeSync { db in
      try Node.where { $0.id.eq(strandID) }.update { $0.name = name; $0.description = desc }.execute(db)
    }
    Log.ingest.info("Strand named: \(name, privacy: .public) (id=\(strandID, privacy: .public))")
  }

  /// One `git show` yields subject, ISO-8601 commit date, and the changed-file list.
  private func gitCommitFields(hash: String, repo: String, fallbackTime: Date)
    -> (subject: String, when: Date, files: String) {
    let raw = Git.run(["show", "--name-only", "--format=%s%n%cI", hash], in: repo) ?? ""
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let subject = lines.first.flatMap { $0.isEmpty ? nil : $0 } ?? hash
    let when = (lines.count > 1 ? ISO8601DateFormatter().date(from: lines[1]) : nil) ?? fallbackTime
    let files = lines.dropFirst(2).filter { !$0.isEmpty }.joined(separator: "\n")
    return (subject, when, files)
  }
}
