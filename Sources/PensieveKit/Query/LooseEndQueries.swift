import Foundation
import SQLiteData

public struct LooseEndView: Sendable {
  public let looseEnd: LooseEnd
  public let occurredAt: Date
  public let ageDays: Int
}

public enum LooseEndQueries {
  public static func open(_ database: any DatabaseReader, nodeID: UUID?, now: Date) throws -> [LooseEndView] {
    try database.read { database in
      let ends: [LooseEnd]
      if let nodeID {
        ends = try LooseEnd.where { $0.nodeID.eq(nodeID) && LooseEnd.isOpen($0) }.fetchAll(database)
      } else {
        ends = try LooseEnd.where { LooseEnd.isOpen($0) }.fetchAll(database)
      }
      var views: [LooseEndView] = []
      for le in ends {
        guard let event = try Event.where({ $0.id.eq(le.sourceEventID) }).fetchOne(database) else { continue }
        let days = Calendar.current.dateComponents([.day], from: event.occurredAt, to: now).day ?? 0
        views.append(LooseEndView(looseEnd: le, occurredAt: event.occurredAt, ageDays: days))
      }
      return views.sorted { $0.occurredAt < $1.occurredAt }   // oldest source first
    }
  }
}
