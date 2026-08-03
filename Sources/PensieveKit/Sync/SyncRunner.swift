import Foundation
import SQLiteData
import GRDB
import os

/// One `sync` cycle: drain the spool, discover + spool new session transcripts, drain again,
/// then run incremental extraction. Pure over injected dependencies (spool, database, provider,
/// projectsDir, clock) so it is testable without touching the live stores or `~/.claude`.
public struct SyncRunner {
  let spool: CaptureSpool
  let database: any DatabaseWriter
  let provider: any LLMProvider
  let projectsDir: URL
  let now: @Sendable () -> Date
  let semanticIndexer: SemanticIndexer?

  public init(spool: CaptureSpool, database: any DatabaseWriter, provider: any LLMProvider,
              projectsDir: URL, now: @escaping @Sendable () -> Date = Date.init,
              semanticIndexer: SemanticIndexer? = nil) {
    self.spool = spool; self.database = database; self.provider = provider
    self.projectsDir = projectsDir; self.now = now; self.semanticIndexer = semanticIndexer
  }

  public struct Summary: Sendable {
    public let ingested: Int
    public let discovered: Int
    public let extracted: Int
  }

  public func run() async throws -> Summary {
    Log.sync.info("Sync cycle start")
    let ingester = Ingester(spool: spool, database: database, llm: provider)
    var ingested = try await ingester.drain()

    let discovered = TranscriptDiscovery.discover(projectsDir: projectsDir, now: now()) { sessionID in
      (try? SessionQueries.isIngested(database, sessionID: sessionID)) ?? false
    }
    for url in discovered {
      try? spool.append(kind: CaptureKind.ccSession,
                        payload: try encodeJSON(SessionRefPayload(transcriptPath: url.path)))
    }
    ingested += try await ingester.drain()
    await ingester.refineProjectNames()
    await ingester.describeProjectNodes()

    let results = try await ExtractionRunner(database: database, provider: provider).run()
    let extracted = results.reduce(0) { $0 + $1.inserted }
    Log.sync.info("Sync complete: ingested=\(ingested, privacy: .public) discovered=\(discovered.count, privacy: .public) extracted=\(extracted, privacy: .public)")

    // Semantic index refresh (best-effort, on-device, toggle-gated). Never blocks the sync summary.
    if let semanticIndexer {
      await semanticIndexer.sync(database)
    } else if PensieveDefaults.semanticSearchEnabled() {
      let embedder = NLContextualEmbedder()
      let store = SemanticIndexStore(url: PensievePaths.semanticIndexURL(),
                                     dimension: embedder.dimension, embedderVersion: embedder.version)
      if store.isAvailable, embedder.dimension > 0 {
        await SemanticIndexer(store: store, embedder: embedder).sync(database)
      }
    }

    return Summary(ingested: ingested, discovered: discovered.count, extracted: extracted)
  }
}
