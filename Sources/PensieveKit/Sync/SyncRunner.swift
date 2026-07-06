import Foundation
import SQLiteData
import GRDB

/// One `sync` cycle: drain the spool, discover + spool new session transcripts, drain again,
/// then run incremental extraction. Pure over injected dependencies (spool, db, provider,
/// projectsDir, clock) so it is testable without touching the live stores or `~/.claude`.
public struct SyncRunner {
  let spool: CaptureSpool
  let db: any DatabaseWriter
  let provider: any LLMProvider
  let projectsDir: URL
  let now: @Sendable () -> Date

  public init(spool: CaptureSpool, db: any DatabaseWriter, provider: any LLMProvider,
              projectsDir: URL, now: @escaping @Sendable () -> Date = Date.init) {
    self.spool = spool; self.db = db; self.provider = provider
    self.projectsDir = projectsDir; self.now = now
  }

  public struct Summary: Sendable {
    public let ingested: Int
    public let discovered: Int
    public let extracted: Int
  }

  public func run() async throws -> Summary {
    let ingester = Ingester(spool: spool, db: db, llm: provider)
    var ingested = try await ingester.drain()

    let discovered = TranscriptDiscovery.discover(projectsDir: projectsDir, now: now()) { sessionID in
      (try? SessionQueries.isIngested(db, sessionID: sessionID)) ?? false
    }
    for url in discovered {
      try? spool.append(kind: CaptureKind.ccSession,
                        payload: try encodeJSON(SessionRefPayload(transcriptPath: url.path)))
    }
    ingested += try await ingester.drain()
    await ingester.refineProjectNames()

    let results = try await ExtractionRunner(db: db, provider: provider).run()
    let extracted = results.reduce(0) { $0 + $1.inserted }
    return Summary(ingested: ingested, discovered: discovered.count, extracted: extracted)
  }
}
