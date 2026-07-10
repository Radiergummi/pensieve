import Foundation
import SQLiteData

// MARK: - JSON-shaped payloads (the stable MCP / prime contract)

public struct BundleLooseEnd: Codable, Sendable {
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

/// One node's grounded state — "reload where this project stands." Loose ends carry verbatim
/// quotes (inside the trust gate); `prose` is best-effort (`nil` on no-events/failure/timeout).
public struct ProjectContextBundle: Codable, Sendable {
  public let nodeID: UUID
  public let name: String
  public let kind: String
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
  public let kind: String
  public let openLooseEnds: Int
  public let daysDormant: Int
  public let score: Double
  public let topLooseEnd: String?
}

public enum SessionContextQueries {
  /// Canonical path → source → node, read-only. Tries the git common-dir first (sources are keyed
  /// on `…/.git`, not the working dir), then the plain canonical path (non-git / claudeCode sources).
  /// Returns nil if the path binds to no node.
  public static func nodeID(forPath path: String, _ db: any DatabaseReader) throws -> UUID? {
    var candidates: [String] = []
    if let common = Git.commonDir(in: path) { candidates.append(common) }  // already symlink-resolved
    candidates.append(ProjectResolver.canonical(path))
    return try db.read { db in
      for key in candidates {
        if let source = try Source.where({ $0.key.eq(key) }).fetchOne(db) {
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
    _ db: any DatabaseReader, now: Date,
    recentLimit: Int = 8,
    summaryBuilder: SummaryBuilder?, providerKind: String,
    cache: NarrationCache?, narrateTimeout: Double = 3.0
  ) async throws -> ProjectContextBundle? {
    // 1. Resolve the node.
    let resolvedID: UUID?
    if let explicitID { resolvedID = explicitID }
    else if let path { resolvedID = try nodeID(forPath: path, db) }
    else { resolvedID = nil }
    guard let id = resolvedID else { return nil }
    guard let facts = try NodeFactsQueries.facts(for: [id], db, now: now).first else { return nil }
    let node = facts.node

    // 2. Grounded pieces (pure queries).
    let ends = try LooseEndQueries.open(db, nodeID: id, now: now)
    let status = try ProjectQueries.status(db, node: node, limit: recentLimit)
    let score = groundedScore(openLooseEnds: facts.openLooseEnds, daysDormant: facts.daysDormant)

    // 3. Prose: cache-first → bounded narrate → nil.
    let key = NarrationCacheKey.make(events: status.recentEvents, provider: providerKind)
    var prose = cache?.get(key)
    if prose == nil, let builder = summaryBuilder {
      prose = await narrateWithin(narrateTimeout, builder: builder, project: node, events: status.recentEvents)
      if let prose { cache?.put(key, prose: prose) }
    }

    return ProjectContextBundle(
      nodeID: id, name: node.name, kind: node.kind, description: node.description, context: node.context,
      daysDormant: facts.daysDormant, openLooseEndCount: facts.openLooseEnds, score: score,
      looseEnds: ends.map { BundleLooseEnd(text: $0.looseEnd.text, quote: $0.looseEnd.quote,
                                           role: $0.looseEnd.role, ageDays: $0.ageDays) },
      recentEvents: status.recentEvents.map { BundleEvent(summary: $0.summary, kind: $0.kind,
                                                          occurredAt: $0.occurredAt) },
      prose: prose)
  }

  /// Ranked "what's next" across all active nodes, optionally restricted to a work/personal
  /// context (unset nodes always show; the opposite explicit context is muted), sliced to
  /// `limit`, each carrying its oldest open loose end's verbatim quote.
  public static func rankedContext(limit: Int, context: String?,
                                   _ db: any DatabaseReader, now: Date) throws -> [WhatsNextItem] {
    let items = try NextQueries.ranked(db, now: now)
    var filtered = items
    if let context, !context.isEmpty {
      let all = try ProjectQueries.all(db)
      let visible = NodeContextResolver.visibleNodeIDs(for: context, in: all)
      filtered = items.filter { visible.contains($0.project.id) }
    }
    return try db.read { db in
      try filtered.prefix(limit).map { item in
        let top = try LooseEnd.where { $0.nodeID.eq(item.project.id) && LooseEnd.isOpen($0) }
          .order { $0.createdAt }.limit(1).fetchOne(db)
        return WhatsNextItem(
          nodeID: item.project.id, name: item.project.name, kind: item.project.kind,
          openLooseEnds: item.openLooseEnds, daysDormant: item.daysDormant, score: item.score,
          topLooseEnd: top?.quote)
      }
    }
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
