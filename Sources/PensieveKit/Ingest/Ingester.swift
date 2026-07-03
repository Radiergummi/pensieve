import Foundation
import SQLiteData

public struct Ingester {
  let spool: CaptureSpool
  let db: any DatabaseWriter
  let resolver: ProjectResolver

  public init(spool: CaptureSpool, db: any DatabaseWriter) {
    self.spool = spool; self.db = db; self.resolver = ProjectResolver(db: db)
  }

  @discardableResult
  public func drain() throws -> Int {
    let rows = try spool.pending()
    var done: [Int64] = []
    for row in rows {
      do {
        try ingest(row)
        done.append(row.id)
      } catch {
        // Leave the row unmarked so it retries next drain; don't abort the batch.
        continue
      }
    }
    try spool.markIngested(done)
    return done.count
  }

  private func ingest(_ row: SpoolRow) throws {
    let data = Data(row.payload.utf8)
    switch row.kind {
    case CaptureKind.gitCommit:
      let p = try JSONDecoder().decode(GitCommitPayload.self, from: data)
      let (project, source) = try resolver.resolve(path: p.repoPath, kind: SourceKind.gitRepo)
      let subject = Git.run(["show", "-s", "--format=%s", p.hash], in: p.repoPath) ?? p.hash
      let when = Git.run(["show", "-s", "--format=%cI", p.hash], in: p.repoPath)
        .flatMap { ISO8601DateFormatter().date(from: $0) } ?? row.ts
      let files = Git.run(["show", "--name-only", "--format=", p.hash], in: p.repoPath) ?? ""
      let detail = try encodeJSON(["hash": p.hash, "branch": p.branch, "files": files])
      let event = Event(projectID: project.id, sourceID: source.id, occurredAt: when,
                        kind: CaptureKind.gitCommit, summary: subject, detailJSON: detail)
      try insert(event)

    case CaptureKind.gitCheckout:
      let p = try JSONDecoder().decode(GitCheckoutPayload.self, from: data)
      let (project, source) = try resolver.resolve(path: p.repoPath, kind: SourceKind.gitRepo)
      let detail = try encodeJSON(["from": p.from, "to": p.to, "branch": p.branch])
      let event = Event(projectID: project.id, sourceID: source.id, occurredAt: row.ts,
                        kind: CaptureKind.gitCheckout, summary: "checkout \(p.branch)", detailJSON: detail)
      try insert(event)

    case CaptureKind.ccSession:
      let p = try JSONDecoder().decode(SessionRefPayload.self, from: data)
      let session = TranscriptParser.parse(fileURL: URL(fileURLWithPath: p.transcriptPath))
      guard let cwd = session.cwd else { return }   // can't attribute without a path
      let (project, source) = try resolver.resolve(path: cwd, kind: SourceKind.claudeCode)
      let detail = try encodeJSON(["sessionID": session.sessionID,
                                   "prompts": String(session.userPromptCount),
                                   "transcriptPath": p.transcriptPath])
      let event = Event(projectID: project.id, sourceID: source.id,
                        occurredAt: session.endedAt ?? row.ts,
                        kind: CaptureKind.ccSession,
                        summary: "session (\(session.userPromptCount) prompts)", detailJSON: detail)
      try insert(event)

    default:
      return   // unknown kind: mark done (drop) — forward-compat, don't wedge the spool
    }
  }

  private func insert(_ event: Event) throws {
    try db.write { db in try Event.insert { event }.execute(db) }
  }
}
