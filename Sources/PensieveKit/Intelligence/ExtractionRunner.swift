import Foundation
import SQLiteData
import GRDB
import os

public struct ExtractionResult: Sendable {
  public let sessionID: String
  public let proposed: Int
  public let verified: Int
  public let inserted: Int
}

public struct ExtractionRunner {
  let database: any DatabaseWriter
  let provider: any LLMProvider
  let now: @Sendable () -> Date

  public init(database: any DatabaseWriter, provider: any LLMProvider,
              now: @escaping @Sendable () -> Date = Date.init) {
    self.database = database; self.provider = provider; self.now = now
  }

  public func run() async throws -> [ExtractionResult] {
    // Every cc.session event is a candidate now — the extract-once filter is gone; a
    // byte-size gate and a message-count watermark decide what (if anything) to re-extract.
    let events = try await database.read { database in
      try Event.where { $0.kind.eq(CaptureKind.ccSession) }.fetchAll(database)
    }

    Log.extraction.info("Extraction start: \(events.count, privacy: .public) sessions to evaluate")

    var results: [ExtractionResult] = []
    for event in events {
      if let result = await extractLooseEnds(from: event) {
        results.append(result)
      }
    }
    Log.extraction.info("Extraction complete: \(results.count, privacy: .public) sessions processed")
    return results
  }

  /// Processes one cc.session event: skip (unreadable/unchanged), legacy-init (watermark only),
  /// or extract + verify + insert. Returns nil whenever there is nothing to report for the
  /// batch summary (skip, legacy-init, or a caught failure) — a single bad session must never
  /// abort the batch or silently advance the watermark.
  private func extractLooseEnds(from event: Event) async -> ExtractionResult? {
    do {
      let detail = (try? JSONDecoder().decode([String: String].self,
                                              from: Data(event.detailJSON.utf8))) ?? [:]
      let fileURL = URL(fileURLWithPath: detail["transcriptPath"] ?? "")

      // Cheap change detector: stat the byte size, no parse. Unreadable/missing → skip
      // (leave the watermark unadvanced so it retries next run; never crash the batch).
      guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
        return nil
      }
      // Unchanged since last extraction → skip (avoids re-parsing multi-MB transcripts).
      if size == event.extractedTranscriptSize {
        Log.extraction.debug("Extraction skip (unchanged): session event \(event.id, privacy: .public)")
        return nil
      }

      let session = TranscriptParser.parse(fileURL: fileURL)
      let messageCount = session.messages.count

      // Legacy init (one-time, no extraction): a row extracted before this feature existed
      // has extractedAt set but size still the -1 "never watermarked" sentinel. Its prior
      // extraction already covered the transcript as it then stood, so initialize the
      // watermark/size WITHOUT extracting — otherwise migration would resurface every
      // previously-resolved loose end.
      if event.extractedAt != nil && event.extractedTranscriptSize == -1 {
        try await database.write { database in
          try Event.where { $0.id.eq(event.id) }.update {
            $0.extractedMessageCount = messageCount
            $0.extractedTranscriptSize = size
          }.execute(database)
        }
        return nil
      }

      // Choose the slice start with a clamp/guard (crash- and misalignment-proof).
      let start: Int
      if messageCount >= event.extractedMessageCount {
        start = event.extractedMessageCount        // normal incremental slice
      } else {
        // Fewer messages than the watermark: the transcript shrank/was rewritten, or the
        // parser now filters more. Re-extract from 0 — the quote-dedup makes this safe.
        start = 0
        Log.extraction.info("Re-extracting \(session.sessionID, privacy: .public) from 0: transcript boundary changed")
      }

      // Extract only the new slice (start <= messages.count always → subscript is valid;
      // an empty slice means nothing new). Verify against the FULL message list: the
      // verifier resolves candidates by absolute messageIndex, so slicing the extractor's
      // INPUT never breaks index resolution or sourceMessageIndex.
      let slice = Array(session.messages[start...])
      let candidates = CandidateFilter.strip(
        try await LooseEndExtractor(provider: provider).extract(from: slice))
      let verified = candidates.compactMap { LooseEndVerifier.verify($0, messages: session.messages) }
      // NOTE: the LLM salience gate (SalienceClassifier) is intentionally NOT wired in here.
      // A hand-labeled eval over 120 real loose ends (docs/superpowers/salience-eval-2026-07-09.md)
      // showed the on-device ~3B model at recall 0.68 — it confidently DROPS genuine loose ends
      // ("going forward, I'd like to combine…") while removing little noise, and is
      // non-deterministic. That is worse than lossless for a "never lose a real loose end" tool.
      // Until the deterministic on-device Create ML classifier + in-app labeling loop lands,
      // extraction stays lossless: every verified (verbatim-cited) loose end is surfaced.
      // SalienceClassifier + classifyNonSalientIndices remain for the eval and future reuse.

      // Best-effort session recap for narration (Part B). `summarize` is non-throwing (nil on
      // failure), computed BEFORE the synchronous database.write. This line is lexically inside the
      // per-session do/catch, but a summary failure can't reach the catch precisely BECAUSE
      // `summarize` is non-throwing — a nil/absent summary must not skip the loose-end insert or
      // the watermark advance. DO NOT add `try` here: it would let a failure abort the session
      // and break that invariant. Summarize the WHOLE session (stable per-session summary).
      let work = await SessionSummarizer(provider: provider).summarize(session.messages)

      let watermark = ExtractionWatermark(messageCount: messageCount, size: size, work: work, stamp: now())
      let inserted = try await insertVerifiedLooseEnds(verified, for: event, watermark: watermark)

      let sessionID = session.sessionID
      let extractionCounts = "proposed=\(candidates.count) verified=\(verified.count) inserted=\(inserted)"
      Log.extraction.info("Extracted session \(sessionID, privacy: .public): \(extractionCounts, privacy: .public)")
      return ExtractionResult(sessionID: session.sessionID,
        proposed: candidates.count, verified: verified.count, inserted: inserted)
    } catch {
      // A single bad session (provider error, etc.) must never abort the batch or
      // silently advance the watermark — leave it unset so it retries next run.
      Log.extraction.error("Extraction failed for session \(event.id, privacy: .public): \(error, privacy: .public)")
      return nil
    }
  }

  /// Inserts newly verified loose ends (deduped against every existing loose end for the node,
  /// regardless of status) and advances the event's extraction watermark, all in one write.
  private func insertVerifiedLooseEnds(
    _ verified: [VerifiedLooseEnd], for event: Event, watermark: ExtractionWatermark
  ) async throws -> Int {
    try await database.write { database -> Int in
      var insertedCount = 0
      // Collapse against ALL existing loose ends in this node (verbatim, normalized),
      // regardless of status: re-extraction (the shrink→0 path re-mines the whole
      // transcript, and a user may restate a quote verbatim) must not resurrect a
      // RESOLVED loose end the user already dismissed. Skip the scan when there is
      // nothing to insert.
      if !verified.isEmpty {
        let existing = try LooseEnd.where { $0.nodeID.eq(event.nodeID) }.fetchAll(database)
        var seen = Set(existing.map { normalizeWhitespace($0.quote) })
        for verifiedLooseEnd in verified {
          let key = normalizeWhitespace(verifiedLooseEnd.quote)
          if seen.contains(key) { continue }   // within- and cross-session dedup
          seen.insert(key)
          try LooseEnd.insert {
            LooseEnd(nodeID: event.nodeID, sourceEventID: event.id, text: verifiedLooseEnd.text,
                     quote: verifiedLooseEnd.quote, role: verifiedLooseEnd.role,
                     sourceMessageIndex: verifiedLooseEnd.sourceMessageIndex)
          }.execute(database)
          insertedCount += 1
        }
      }
      // Advance the watermark, size, and last-extracted stamp in the same write.
      try Event.where { $0.id.eq(event.id) }.update {
        $0.extractedAt = #bind(watermark.stamp)
        $0.extractedMessageCount = watermark.messageCount
        $0.extractedTranscriptSize = watermark.size
        $0.workSummary = watermark.work ?? event.workSummary
      }.execute(database)
      return insertedCount
    }
  }
}

/// The extraction-watermark fields advanced together with a loose-end insert, bundled to keep
/// `insertVerifiedLooseEnds` within the project's function-parameter-count limit.
private struct ExtractionWatermark {
  let messageCount: Int
  let size: Int
  let work: String?
  let stamp: Date
}
