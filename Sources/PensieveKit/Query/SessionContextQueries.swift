import Foundation
import SQLiteData

// MARK: - JSON-shaped payloads (the stable MCP / prime contract)

public struct BundleLooseEnd: Codable, Sendable {
  public let id: UUID
  public let text: String
  public let quote: String
  public let role: String
  public let ageDays: Int
}

public struct BundleEvent: Codable, Sendable {
  public let summary: String
  public let kind: String
  public let occurredAt: Date
}

public struct RecallMessage: Codable, Sendable {
  public let index: Int
  public let role: String
  public let text: String
  public let isCited: Bool
  public let isUserPrompt: Bool
}

/// A loose end's surrounding transcript window — the MCP `recall` contract. Verbatim only.
public struct RecallBundle: Codable, Sendable {
  public let looseEndText: String
  public let quote: String
  public let transcriptAvailable: Bool
  public let sessionOccurredAt: Date
  public let messages: [RecallMessage]   // empty when transcriptAvailable == false
}

/// One node's grounded state — "reload where this project stands." Loose ends carry verbatim
/// quotes (inside the trust gate); `prose` is best-effort (`nil` on no-events/failure/timeout).
public struct ProjectContextBundle: Codable, Sendable {
  public let nodeID: UUID
  public let name: String
  public let kind: NodeKind
  public let description: String
  public let context: String
  public let daysDormant: Int
  public let openLooseEndCount: Int
  public let score: Double
  public let looseEnds: [BundleLooseEnd]
  public let recentEvents: [BundleEvent]
  public let prose: String?
}

/// One ranked "what's next" row: score signals + the top cited loose end (verbatim quote).
public struct WhatsNextItem: Codable, Sendable {
  public let nodeID: UUID
  public let name: String
  public let kind: NodeKind
  public let openLooseEnds: Int
  public let daysDormant: Int
  public let score: Double
  public let topLooseEnd: String?
}

/// How (and whether) a context bundle may produce prose. A nil `summaryBuilder` means
/// cache-read-only — the `prime` hook never narrates.
public struct NarrationOptions: Sendable {
  public var summaryBuilder: SummaryBuilder?
  public var providerKind: String
  public var cache: NarrationCache?
  public var timeout: Double
  public init(summaryBuilder: SummaryBuilder?, providerKind: String, cache: NarrationCache?, timeout: Double = 3.0) {
    self.summaryBuilder = summaryBuilder
    self.providerKind = providerKind
    self.cache = cache
    self.timeout = timeout
  }
}

public enum SessionContextQueries {
  /// Canonical path → source → node, read-only. Tries the git common-dir first (sources are keyed
  /// on `…/.git`, not the working dir), then the plain canonical path (non-git / claudeCode sources).
  /// Returns nil if the path binds to no node.
  public static func nodeID(forPath path: String, _ database: any DatabaseReader) throws -> UUID? {
    var candidates: [String] = []
    if let common = Git.commonDir(in: path) { candidates.append(common) }  // already symlink-resolved
    candidates.append(ProjectResolver.canonical(path))
    return try database.read { database in
      for key in candidates {
        if let source = try Source.where({ $0.key.eq(key) }).fetchOne(database) {
          return source.nodeID
        }
      }
      return nil
    }
  }

  /// The grounded bundle for a node identified by `nodeID` (preferred) or `path`. Read-only.
  /// Prose is cache-first → bounded narrate → nil:
  ///   • `summaryBuilder == nil`  → cache-read-only (the `prime` hook: never narrates).
  ///   • `summaryBuilder != nil`  → on a cache miss, narrate under `narrateTimeout`s and write
  ///     through on success; `nil` on no-events/failure/timeout (never a facts-dump).
  public static func bundle(
    forPath path: String?, nodeID explicitID: UUID?,
    _ database: any DatabaseReader, now: Date,
    recentLimit: Int = 8,
    narration: NarrationOptions
  ) async throws -> ProjectContextBundle? {
    // 1. Resolve the node.
    let resolvedID: UUID?
    if let explicitID {
      resolvedID = explicitID
    } else if let path {
      resolvedID = try nodeID(forPath: path, database)
    } else {
      resolvedID = nil
    }
    guard let id = resolvedID else { return nil }
    guard let facts = try NodeFactsQueries.facts(for: [id], database, now: now).first else { return nil }
    let node = facts.node

    // 2. Grounded pieces (pure queries).
    let ends = try LooseEndQueries.open(database, nodeID: id, now: now)
    let status = try ProjectQueries.status(database, node: node, limit: recentLimit)
    let score = groundedScore(openLooseEnds: facts.openLooseEnds, daysDormant: facts.daysDormant)

    // 3. Prose: cache-first → bounded narrate → nil.
    let key = NarrationCacheKey.make(events: status.recentEvents, provider: narration.providerKind)
    var prose = narration.cache?.get(key)
    if prose == nil, let builder = narration.summaryBuilder {
      prose = await narrateWithin(narration.timeout, builder: builder, project: node, events: status.recentEvents)
      if let prose { narration.cache?.put(key, prose: prose) }
    }

    return ProjectContextBundle(
      nodeID: id, name: node.name, kind: node.kind, description: node.description, context: node.context,
      daysDormant: facts.daysDormant, openLooseEndCount: facts.openLooseEnds, score: score,
      looseEnds: ends.map { BundleLooseEnd(id: $0.looseEnd.id, text: $0.looseEnd.text,
                                           quote: $0.looseEnd.quote, role: $0.looseEnd.role,
                                           ageDays: $0.ageDays) },
      recentEvents: status.recentEvents.map { BundleEvent(summary: $0.summary, kind: $0.kind,
                                                          occurredAt: $0.occurredAt) },
      prose: prose)
  }

  /// Ranked "what's next" across all active nodes, optionally restricted to a work/personal
  /// context (unset nodes always show; the opposite explicit context is muted), sliced to
  /// `limit`, each carrying its oldest open loose end's verbatim quote.
  public static func rankedContext(limit: Int, context: String?,
                                   _ database: any DatabaseReader, now: Date) throws -> [WhatsNextItem] {
    let items = try NextQueries.ranked(database, now: now).filter(\.isActionable)
    var filtered = items
    if let context, !context.isEmpty {
      let all = try ProjectQueries.all(database)
      let visible = NodeContextResolver.visibleNodeIDs(for: context, in: all)
      filtered = items.filter { visible.contains($0.project.id) }
    }
    return try database.read { database in
      try filtered.prefix(limit).map { item in
        let top = try LooseEnd.where { $0.nodeID.eq(item.project.id) && LooseEnd.isOpen($0) }
          .order { $0.createdAt }.limit(1).fetchOne(database)
        return WhatsNextItem(
          nodeID: item.project.id, name: item.project.name, kind: item.project.kind,
          openLooseEnds: item.openLooseEnds, daysDormant: item.daysDormant, score: item.score,
          topLooseEnd: top?.quote)
      }
    }
  }

  /// Recall the transcript conversation around a loose end. Fetches the LooseEnd by UUID and
  /// delegates to the tested `ProvenanceQueries.context(radius:)` — no LLM, verbatim only, inside
  /// the trust gate. Returns nil if the id resolves to no loose end; a bundle with
  /// `transcriptAvailable == false` (+ the stored quote) if the transcript is gone.
  public static func recall(looseEndID: UUID, radius: Int,
                            _ database: any DatabaseReader) throws -> RecallBundle? {
    guard let looseEnd = try database.read({ database in
      try LooseEnd.where { $0.id.eq(looseEndID) }.fetchOne(database)
    }) else { return nil }
    let ctx = try ProvenanceQueries.context(database, looseEnd: looseEnd, radius: radius)
    return RecallBundle(
      looseEndText: looseEnd.text, quote: looseEnd.quote,
      transcriptAvailable: ctx.transcriptAvailable,
      sessionOccurredAt: ctx.sourceEvent.occurredAt,
      messages: ctx.messages.map { RecallMessage(index: $0.index, role: $0.role, text: $0.text,
                                                 isCited: $0.isCited, isUserPrompt: $0.isUserPrompt) })
  }

  /// Races `narrate` against a timeout; returns nil if the model doesn't answer in time (FM
  /// cold-start can be ≫ a couple seconds and the caller is blocking on the result).
  private static func narrateWithin(_ seconds: Double, builder: SummaryBuilder,
                                    project: Node, events: [Event]) async -> String? {
    await withTaskGroup(of: String?.self) { group in
      group.addTask { await builder.narrate(project: project, events: events) }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }
}
