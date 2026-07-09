import Foundation
import SQLiteData

public struct LooseEndView: Sendable {
  public let looseEnd: LooseEnd
  public let occurredAt: Date
  public let ageDays: Int
}

public enum LooseEndQueries {
  public static func open(_ db: any DatabaseReader, nodeID: UUID?, now: Date) throws -> [LooseEndView] {
    try db.read { db in
      let ends: [LooseEnd]
      if let nodeID {
        ends = try LooseEnd.where { $0.nodeID.eq(nodeID) && $0.status.eq("open") && $0.label.neq("noise") }.fetchAll(db)
      } else {
        ends = try LooseEnd.where { $0.status.eq("open") && $0.label.neq("noise") }.fetchAll(db)
      }
      var views: [LooseEndView] = []
      for le in ends {
        guard let event = try Event.where({ $0.id.eq(le.sourceEventID) }).fetchOne(db) else { continue }
        let days = Calendar.current.dateComponents([.day], from: event.occurredAt, to: now).day ?? 0
        views.append(LooseEndView(looseEnd: le, occurredAt: event.occurredAt, ageDays: days))
      }
      return views.sorted { $0.occurredAt < $1.occurredAt }   // oldest source first
    }
  }
}
