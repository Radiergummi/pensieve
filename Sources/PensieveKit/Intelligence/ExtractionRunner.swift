import Foundation
import SQLiteData
import GRDB

public struct ExtractionResult: Sendable {
  public let sessionID: String
  public let proposed: Int
  public let verified: Int
  public let inserted: Int
}

public struct ExtractionRunner {
  let db: any DatabaseWriter
  let provider: any LLMProvider
  let now: @Sendable () -> Date

  public init(db: any DatabaseWriter, provider: any LLMProvider,
              now: @escaping @Sendable () -> Date = Date.init) {
    self.db = db; self.provider = provider; self.now = now
  }

  public func run() async throws -> [ExtractionResult] {
    let pending = try await db.read { db in
      try Event.where { $0.kind.eq(CaptureKind.ccSession) }.fetchAll(db)
    }.filter { $0.extractedAt == nil }

    var results: [ExtractionResult] = []
    for event in pending {
      do {
        let detail = (try? JSONDecoder().decode([String: String].self,
                                                from: Data(event.detailJSON.utf8))) ?? [:]
        let transcriptPath = detail["transcriptPath"] ?? ""
        let session = TranscriptParser.parse(fileURL: URL(fileURLWithPath: transcriptPath))

        let candidates = try await LooseEndExtractor(provider: provider).extract(from: session.messages)
        let verified = candidates.compactMap { LooseEndVerifier.verify($0, messages: session.messages) }

        let stamp = now()
        let inserted = try await db.write { db -> Int in
          // Collapse against existing OPEN loose ends in this project (verbatim, normalized).
          let existing = try LooseEnd.where { $0.nodeID.eq(event.nodeID) }.fetchAll(db)
          var seen = Set(existing.filter { $0.status == "open" }.map { normalizeWhitespace($0.quote) })
          var insertedCount = 0
          for v in verified {
            let key = normalizeWhitespace(v.quote)
            if seen.contains(key) { continue }   // within- and cross-session dedup
            seen.insert(key)
            try LooseEnd.insert {
              LooseEnd(nodeID: event.nodeID, sourceEventID: event.id, text: v.text,
                       quote: v.quote, role: v.role, sourceMessageIndex: v.sourceMessageIndex)
            }.execute(db)
            insertedCount += 1
          }
          try Event.where { $0.id.eq(event.id) }.update { $0.extractedAt = #bind(stamp) }.execute(db)
          return insertedCount
        }

        results.append(ExtractionResult(sessionID: session.sessionID,
          proposed: candidates.count, verified: verified.count, inserted: inserted))
      } catch {
        // A single bad session (provider error, etc.) must never abort the batch or
        // silently mark the event extracted — leave extractedAt unset so it retries.
        FileHandle.standardError.write(Data("pensieve: extraction failed for session \(event.id): \(error)\n".utf8))
        continue
      }
    }
    return results
  }
}
