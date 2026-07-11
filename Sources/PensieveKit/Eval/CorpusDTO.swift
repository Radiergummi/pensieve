import Foundation

public struct TranscriptMessageDTO: Codable, Sendable {
  public var index: Int; public var role: String; public var text: String
  public var timestamp: Date?; public var isUserPrompt: Bool
  public init(_ m: TranscriptMessage) {
    index = m.index; role = m.role; text = m.text; timestamp = m.timestamp; isUserPrompt = m.isUserPrompt
  }
  public func toDomain() -> TranscriptMessage {
    TranscriptMessage(index: index, role: role, text: text, timestamp: timestamp, isUserPrompt: isUserPrompt)
  }
}

public struct EventDTO: Codable, Sendable {
  public var id: UUID; public var nodeID: UUID; public var sourceID: UUID
  public var occurredAt: Date; public var kind: String; public var summary: String
  public var detailJSON: String; public var fingerprint: String?; public var branchKey: String?
  public var extractedAt: Date?; public var extractedMessageCount: Int; public var extractedTranscriptSize: Int
  public var workSummary: String?; public var createdAt: Date
  public init(_ e: Event) {
    id = e.id; nodeID = e.nodeID; sourceID = e.sourceID; occurredAt = e.occurredAt; kind = e.kind
    summary = e.summary; detailJSON = e.detailJSON; fingerprint = e.fingerprint; branchKey = e.branchKey
    extractedAt = e.extractedAt; extractedMessageCount = e.extractedMessageCount
    extractedTranscriptSize = e.extractedTranscriptSize; workSummary = e.workSummary; createdAt = e.createdAt
  }
  public func toDomain() -> Event {
    Event(id: id, nodeID: nodeID, sourceID: sourceID, occurredAt: occurredAt, kind: kind, summary: summary,
          detailJSON: detailJSON, fingerprint: fingerprint, branchKey: branchKey, extractedAt: extractedAt,
          extractedMessageCount: extractedMessageCount, extractedTranscriptSize: extractedTranscriptSize,
          workSummary: workSummary, createdAt: createdAt)
  }
}

public struct ProjectContextDTO: Codable, Sendable {
  public var dirName: String; public var gitRemote: String?; public var readmeHead: String?
  public var claudeMdHead: String?; public var manifest: String?
  public init(_ c: ProjectContext) {
    dirName = c.dirName; gitRemote = c.gitRemote; readmeHead = c.readmeHead
    claudeMdHead = c.claudeMdHead; manifest = c.manifest
  }
  public func toDomain() -> ProjectContext {
    ProjectContext(dirName: dirName, gitRemote: gitRemote, readmeHead: readmeHead,
                   claudeMdHead: claudeMdHead, manifest: manifest)
  }
}

public struct ExtractionCorpusItem: Codable, Sendable {
  public var id: String; public var shape: String; public var messages: [TranscriptMessageDTO]
  public init(id: String, shape: String, messages: [TranscriptMessageDTO]) {
    self.id = id; self.shape = shape; self.messages = messages
  }
}
public struct NarrationCorpusItem: Codable, Sendable {
  public var id: String; public var nodeName: String; public var events: [EventDTO]
  public init(id: String, nodeName: String, events: [EventDTO]) {
    self.id = id; self.nodeName = nodeName; self.events = events
  }
}
public struct DescriptionCorpusItem: Codable, Sendable {
  public var id: String; public var context: ProjectContextDTO
  public init(id: String, context: ProjectContextDTO) { self.id = id; self.context = context }
}

public enum CorpusItem: Sendable {
  case extraction(ExtractionCorpusItem)
  case narration(NarrationCorpusItem)
  case description(DescriptionCorpusItem)
  public var id: String {
    switch self {
    case .extraction(let i): return i.id
    case .narration(let i): return i.id
    case .description(let i): return i.id
    }
  }
}
