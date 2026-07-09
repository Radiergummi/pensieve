import Foundation
import SQLiteData

@Table
public struct LooseEnd: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var nodeID: UUID
  public var sourceEventID: UUID
  public var text: String        // the open item
  public var quote: String       // verbatim provenance from captured text
  public var status: String      // "open" | "resolved"
  public var role: String            // role of the cited message (e.g. "user")
  public var sourceMessageIndex: Int // index of the cited message within the transcript
  public var label: String           // human-confirmed salience: "" unlabeled | "salient" | "noise"
  public var labelSuggestion: String // machine-suggested salience (same values); never enters the corpus
  public var createdAt: Date
  public init(id: UUID = UUID(), nodeID: UUID, sourceEventID: UUID, text: String,
              quote: String, status: String = "open", role: String = "",
              sourceMessageIndex: Int = 0, label: String = "", labelSuggestion: String = "",
              createdAt: Date = Date()) {
    self.id = id; self.nodeID = nodeID; self.sourceEventID = sourceEventID
    self.text = text; self.quote = quote; self.status = status
    self.role = role; self.sourceMessageIndex = sourceMessageIndex
    self.label = label; self.labelSuggestion = labelSuggestion; self.createdAt = createdAt
  }
}
