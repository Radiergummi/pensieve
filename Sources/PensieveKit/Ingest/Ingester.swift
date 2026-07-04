import Foundation
import SQLiteData
import GRDB

public struct Ingester {
  let spool: CaptureSpool
  let db: any DatabaseWriter
  let resolver: ProjectResolver

  public init(spool: CaptureSpool, db: any DatabaseWriter) {
    self.spool = spool; self.db = db; self.resolver = ProjectResolver(db: db)
  }

  enum IngestError: Error { case unattributableSession }

  /// Drains all pending spool rows. Returns the number of canonical events CREATED
  /// (not rows processed — a dropped unknown-kind row counts 0). A row that throws is
  /// left unmarked so it retries next drain; successful and dropped rows are marked
  /// ingested per-row so progress is durable even if a later row fails.
  @discardableResult
  public func drain() throws -> Int {
    let rows = try spool.pending()
    var created = 0
    for row in rows {
      do {
        let n = try ingest(row)
        try spool.markIngested([row.id])
        created += n
      } catch {
        continue   // leave unmarked; retry next drain
      }
    }
    return created
  }

  /// Returns the number of events created (0 for a dropped unknown kind).
  private func ingest(_ row: SpoolRow) throws -> Int {
    let data = Data(row.payload.utf8)
    switch row.kind {
    case CaptureKind.gitCommit:
      let p = try JSONDecoder().decode(GitCommitPayload.self, from: data)
      let key = Git.commonDir(in: p.repoPath) ?? ProjectResolver.canonical(p.repoPath)
      let branchKey = Git.strandBranchKey(branch: p.branch, defaultBranch: Git.defaultBranch(in: p.repoPath))
      let fields = gitCommitFields(hash: p.hash, repo: p.repoPath, fallbackTime: row.ts)
      let detail = try encodeJSON(["hash": p.hash, "branch": p.branch, "files": fields.files])
      let inserted = try db.write { db -> Bool in
        let (project, source) = try resolver.resolve(db, path: key, kind: SourceKind.gitRepo)
        return try insertIfNew(db, Event(nodeID: project.id, sourceID: source.id, occurredAt: fields.when,
              kind: CaptureKind.gitCommit, summary: fields.subject, detailJSON: detail,
              fingerprint: Fingerprint.commit(hash: p.hash), branchKey: branchKey))
      }
      return inserted ? 1 : 0

    case CaptureKind.gitCheckout:
      let p = try JSONDecoder().decode(GitCheckoutPayload.self, from: data)
      let key = Git.commonDir(in: p.repoPath) ?? ProjectResolver.canonical(p.repoPath)
      let detail = try encodeJSON(["from": p.from, "to": p.to, "branch": p.branch])
      let inserted = try db.write { db -> Bool in
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
      // No cwd → transcript missing / not yet flushed. THROW so the row stays pending
      // and retries next drain, instead of being silently dropped.
      guard let cwd = session.cwd else { throw IngestError.unattributableSession }
      // Attribute to the git repo ROOT (matching how commits are keyed), not the raw cwd,
      // so a session launched from a subdirectory lands in the same project as its commits.
      let key = Git.commonDir(in: cwd) ?? ProjectResolver.canonical(cwd)
      let detail = try encodeJSON(["sessionID": session.sessionID,
                                   "prompts": String(session.userPromptCount),
                                   "transcriptPath": p.transcriptPath])
      let inserted = try db.write { db -> Bool in
        let (project, source) = try resolver.resolve(db, path: key, kind: SourceKind.claudeCode)
        let branchKey: String? = {
          guard let sb = try? SessionBranch.where({ $0.sessionID.eq(session.sessionID) }).fetchOne(db),
                let raw = sb.branch else { return nil }
          return Git.strandBranchKey(branch: raw, defaultBranch: Git.defaultBranch(in: sb.commonDir))
        }()
        return try insertIfNew(db, Event(nodeID: project.id, sourceID: source.id,
              occurredAt: session.endedAt ?? row.ts, kind: CaptureKind.ccSession,
              summary: "session (\(session.userPromptCount) prompts)", detailJSON: detail,
              fingerprint: Fingerprint.session(sessionID: session.sessionID), branchKey: branchKey))
      }
      return inserted ? 1 : 0

    case CaptureKind.ccSessionStart:
      let p = try JSONDecoder().decode(SessionStartPayload.self, from: data)
      try db.write { db in
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

  /// Inserts the event only if no event with the same (sourceID, fingerprint) exists.
  /// Returns whether an insert actually happened (false when deduped).
  private func insertIfNew(_ db: Database, _ event: Event) throws -> Bool {
    let exists = try Event
      .where { $0.sourceID.eq(event.sourceID) && $0.fingerprint.eq(event.fingerprint) }
      .fetchOne(db) != nil
    if exists { return false }
    try Event.insert { event }.execute(db)
    return true
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
