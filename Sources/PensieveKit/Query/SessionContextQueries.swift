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
}
