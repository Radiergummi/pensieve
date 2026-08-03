import Foundation
import SQLiteData

/// The action-first sidebar's grounded buckets, derived from the deterministic `NextQueries` ranking.
/// No model, no invented signal. "Blocked" and "Roads Not Taken" are intentionally absent until their
/// grounded signal / fork backend exist.
public struct SmartLists: Sendable {
  public let whatsNext: [NextItem]
  public let dormant: [NextItem]
  public let recentlyActive: [NextItem]

  public init(whatsNext: [NextItem], dormant: [NextItem], recentlyActive: [NextItem]) {
    self.whatsNext = whatsNext; self.dormant = dormant; self.recentlyActive = recentlyActive
  }

  public static func compute(_ database: any DatabaseWriter, now: Date,
                             dormantAfterDays: Int = 14,
                             activeWithinDays: Int = 3) throws -> SmartLists {
    let ranked = try NextQueries.ranked(database, now: now)
    let dormant = ranked
      .filter { $0.daysDormant >= dormantAfterDays }
      .sorted { $0.daysDormant > $1.daysDormant }
    let recentlyActive = ranked
      .filter { $0.daysDormant <= activeWithinDays }
      .sorted { $0.daysDormant < $1.daysDormant }
    return SmartLists(whatsNext: ranked, dormant: dormant, recentlyActive: recentlyActive)
  }
}
