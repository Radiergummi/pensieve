import Foundation
import SQLiteData

@Table
public struct SessionBranch: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var sessionID: String
  public var branch: String?      // raw abbrev-ref at launch; nil = non-git / no branch
  public var commonDir: String    // repo identity (git common-dir), "" for non-git
  public var createdAt: Date
  public init(id: UUID = UUID(), sessionID: String, branch: String?, commonDir: String, createdAt: Date = Date()) {
    self.id = id; self.sessionID = sessionID; self.branch = branch
    self.commonDir = commonDir; self.createdAt = createdAt
  }
}
