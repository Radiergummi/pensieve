import Foundation
import SQLiteData
import GRDB

/// The offline bootstrap labeler: over the STORED loose-end backlog (not live extraction), it
/// re-parses each loose end's transcript for context, classifies deferred-vs-in-the-moment via the
/// injected provider (Haiku, from the CLI), and writes `labelSuggestion` ONLY. Never touches the
/// human `label`. A batch whose provider call fails writes nothing, so a re-run retries it.
public struct SalienceSuggester {
  public struct Summary: Sendable, Equatable {
    public let candidates: Int, suggested: Int, salient: Int, noise: Int
    public let quoteOnly: Int, skipped: Int
  }

  private let provider: any LLMProvider
  private let batchCharBudget: Int
  private let parse: @Sendable (URL) -> ParsedSession

  public init(provider: any LLMProvider, batchCharBudget: Int = 2000,
              parse: @escaping @Sendable (URL) -> ParsedSession = { TranscriptParser.parse(fileURL: $0) }) {
    self.provider = provider
    self.batchCharBudget = batchCharBudget
    self.parse = parse
  }

  private struct Item { let id: UUID; let quote: String; let context: String }

  public func run(_ database: any DatabaseWriter, limit: Int?, force: Bool) async throws -> Summary {
    // 1. Candidates: open + unlabeled; skip already-suggested unless `force`. Deterministic order
    //    (createdAt) so `--limit` is reproducible.
    let candidates: [LooseEnd] = try await database.read { database in
      let rows = try LooseEnd.where { $0.status.eq("open") && $0.label.eq(LooseEndLabel.unlabeled) }.fetchAll(database)
      return rows.filter { force || $0.labelSuggestion.isEmpty }
                 .sorted { $0.createdAt < $1.createdAt }
    }
    let capped = limit.map { Array(candidates.prefix($0)) } ?? candidates

    // 2. Group by source event; parse each transcript ONCE; render each item's context window.
    //    A missing/empty transcript → quote-only ("" context).
    var items: [Item] = []
    var quoteOnly = 0
    let byEvent = Dictionary(grouping: capped, by: { $0.sourceEventID })
    for (eventID, group) in byEvent {
      let messages = try messages(database, eventID: eventID)
      for looseEnd in group {
        let vle = VerifiedLooseEnd(text: looseEnd.text, quote: looseEnd.quote, role: looseEnd.role,
                                   sourceMessageIndex: looseEnd.sourceMessageIndex)
        let ctx = messages.isEmpty ? "" : SalienceClassifier.contextWindow(for: vle, messages: messages)
        if messages.isEmpty { quoteOnly += 1 }
        items.append(Item(id: looseEnd.id, quote: looseEnd.quote, context: ctx))
      }
    }

    // 3. Batch flat by cost; classify; write. Provider failure (nil) → skip the batch (write nothing).
    var suggested = 0, salient = 0, noise = 0, skipped = 0
    for batch in Self.batches(items, budget: batchCharBudget) {
      let prompt = SalienceClassifier.buildPrompt(batch.map { (quote: $0.quote, context: $0.context) })
      guard let dropIdx = try? await provider.classifyNonSalientIndices(prompt: prompt) else {
        skipped += batch.count
        continue
      }
      let dropSet = Set(dropIdx)
      for (n, it) in batch.enumerated() {
        let label = dropSet.contains(n) ? LooseEndLabel.noise : LooseEndLabel.salient
        _ = try? LooseEndCommands.suggest(database, id: it.id, label: label)
        suggested += 1
        if label == LooseEndLabel.salient { salient += 1 } else { noise += 1 }
      }
    }
    return Summary(candidates: capped.count, suggested: suggested, salient: salient,
                   noise: noise, quoteOnly: quoteOnly, skipped: skipped)
  }

  /// Parse the event's transcript (best-effort). Returns [] on missing event / no path / empty parse.
  private func messages(_ database: any DatabaseWriter, eventID: UUID) throws -> [TranscriptMessage] {
    guard let event = try database.read({ database in try Event.where { $0.id.eq(eventID) }.fetchOne(database) }) else { return [] }
    let detail = (try? JSONDecoder().decode([String: String].self, from: Data(event.detailJSON.utf8))) ?? [:]
    guard let path = detail["transcriptPath"], !path.isEmpty else { return [] }
    return parse(URL(fileURLWithPath: path)).messages
  }

  /// Flat cost-bounded batching (quote + context + tag overhead), mirroring SalienceClassifier.batches
  /// but over pre-rendered items rather than (ends, shared messages).
  private static func batches(_ items: [Item], budget: Int) -> [[Item]] {
    var out: [[Item]] = [], current: [Item] = [], size = 0
    for it in items {
      let cost = it.quote.count + it.context.count + 16
      if size + cost > budget, !current.isEmpty { out.append(current); current = []; size = 0 }
      current.append(it); size += cost
    }
    if !current.isEmpty { out.append(current) }
    return out
  }
}
