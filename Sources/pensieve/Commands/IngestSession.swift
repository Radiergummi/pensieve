import ArgumentParser
import PensieveKit

struct IngestSession: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ingest-session",
    abstract: "Record a Claude Code transcript for ingestion.")
  @Option var path: String
  func run() throws {
    let payload = SessionRefPayload(transcriptPath: path)
    try openSpool().append(kind: CaptureKind.ccSession, payload: try encodeJSON(payload))
  }
}
