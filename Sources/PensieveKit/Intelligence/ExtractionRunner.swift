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
    // Every cc.session event is a candidate now — the extract-once filter is gone; a
    // byte-size gate and a message-count watermark decide what (if anything) to re-extract.
    let events = try await db.read { db in
      try Event.where { $0.kind.eq(CaptureKind.ccSession) }.fetchAll(db)
    }

    var results: [ExtractionResult] = []
    for event in events {
      do {
        let detail = (try? JSONDecoder().decode([String: String].self,
                                                from: Data(event.detailJSON.utf8))) ?? [:]
        let fileURL = URL(fileURLWithPath: detail["transcriptPath"] ?? "")

        // Cheap change detector: stat the byte size, no parse. Unreadable/missing → skip
        // (leave the watermark unadvanced so it retries next run; never crash the batch).
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
          continue
        }
        // Unchanged since last extraction → skip (avoids re-parsing multi-MB transcripts).
        if size == event.extractedTranscriptSize { continue }

        let session = TranscriptParser.parse(fileURL: fileURL)
        let messageCount = session.messages.count

        // Legacy init (one-time, no extraction): a row extracted before this feature existed
        // has extractedAt set but size still the -1 "never watermarked" sentinel. Its prior
        // extraction already covered the transcript as it then stood, so initialize the
        // watermark/size WITHOUT extracting — otherwise migration would resurface every
        // previously-resolved loose end.
        if event.extractedAt != nil && event.extractedTranscriptSize == -1 {
          try await db.write { db in
            try Event.where { $0.id.eq(event.id) }.update {
              $0.extractedMessageCount = messageCount
              $0.extractedTranscriptSize = size
            }.execute(db)
          }
          continue
        }

        // Choose the slice start with a clamp/guard (crash- and misalignment-proof).
        let start: Int
        if messageCount >= event.extractedMessageCount {
          start = event.extractedMessageCount        // normal incremental slice
        } else {
          // Fewer messages than the watermark: the transcript shrank/was rewritten, or the
          // parser now filters more. Re-extract from 0 — the quote-dedup makes this safe.
          start = 0
          FileHandle.standardError.write(Data(
            "pensieve: re-extracting \(session.sessionID) from 0: transcript boundary changed\n".utf8))
        }

        // Extract only the new slice (start <= messages.count always → subscript is valid;
        // an empty slice means nothing new). Verify against the FULL message list: the
        // verifier resolves candidates by absolute messageIndex, so slicing the extractor's
        // INPUT never breaks index resolution or sourceMessageIndex.
        let slice = Array(session.messages[start...])
        let candidates = try await LooseEndExtractor(provider: provider).extract(from: slice)
        let verified = candidates.compactMap { LooseEndVerifier.verify($0, messages: session.messages) }

        let stamp = now()
        let inserted = try await db.write { db -> Int in
          // Collapse against existing OPEN loose ends in this node (verbatim, normalized).
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
          // Advance the watermark, size, and last-extracted stamp in the same write.
          try Event.where { $0.id.eq(event.id) }.update {
            $0.extractedAt = #bind(stamp)
            $0.extractedMessageCount = messageCount
            $0.extractedTranscriptSize = size
          }.execute(db)
          return insertedCount
        }

        results.append(ExtractionResult(sessionID: session.sessionID,
          proposed: candidates.count, verified: verified.count, inserted: inserted))
      } catch {
        // A single bad session (provider error, etc.) must never abort the batch or
        // silently advance the watermark — leave it unset so it retries next run.
        FileHandle.standardError.write(Data("pensieve: extraction failed for session \(event.id): \(error)\n".utf8))
        continue
      }
    }
    return results
  }
}
