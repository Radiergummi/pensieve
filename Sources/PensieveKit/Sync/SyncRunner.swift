import Foundation
import SQLiteData
import GRDB
import os

/// One `sync` cycle: drain the spool, discover + spool new session transcripts, drain again,
/// then run incremental extraction. Pure over injected dependencies (spool, db, provider,
/// projectsDir, clock) so it is testable without touching the live stores or `~/.claude`.
public struct SyncRunner {
  let spool: CaptureSpool
  let db: any DatabaseWriter
  let provider: any LLMProvider
  let projectsDir: URL
  let now: @Sendable () -> Date
  let textIndexStore: TextIndexStore?

  public init(spool: CaptureSpool, db: any DatabaseWriter, provider: any LLMProvider,
              projectsDir: URL, now: @escaping @Sendable () -> Date = Date.init,
              textIndexStore: TextIndexStore? = nil) {
    self.spool = spool; self.db = db; self.provider = provider
    self.projectsDir = projectsDir; self.now = now; self.textIndexStore = textIndexStore
  }

  public struct Summary: Sendable {
    public let ingested: Int
    public let discovered: Int
    public let extracted: Int
  }

  public func run() async throws -> Summary {
    Log.sync.info("Sync cycle start")
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
    await ingester.describeProjectNodes()

    let results = try await ExtractionRunner(db: db, provider: provider).run()
    let extracted = results.reduce(0) { $0 + $1.inserted }
    Log.sync.info("Sync complete: ingested=\(ingested, privacy: .public) discovered=\(discovered.count, privacy: .public) extracted=\(extracted, privacy: .public)")

    // Keyword index refresh (best-effort, toggle-gated). Never blocks the sync summary: a rebuild
    // is a whole-table rewrite of ~2k short rows and short-circuits on an unchanged fingerprint.
    if PensieveDefaults.semanticSearchEnabled() {
      let store = textIndexStore ?? TextIndexStore(url: PensievePaths.textIndexURL())
      if store.isAvailable, let corpus = try? EmbeddableCorpus.gather(db) {
        store.rebuild(items: corpus)
      }
    }

    return Summary(ingested: ingested, discovered: discovered.count, extracted: extracted)
  }
}
