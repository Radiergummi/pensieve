import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// Writes a minimal JSONL transcript and returns its URL. Lines are (type, text);
/// type "user" prose → isUserPrompt true; "assistant" or a tool_result → false.
private func writeTranscript(_ prefix: String, _ lines: [(type: String, text: String)]) throws -> URL {
  let url = tempURL(prefix, ext: "jsonl")
  let jsonl = lines.map { line in
    #"{"type":"\#(line.type)","cwd":"/p/app","timestamp":"2026-06-29T13:03:43.382Z","message":{"role":"\#(line.type)","content":"\#(line.text)"}}"#
  }.joined(separator: "\n")
  try jsonl.write(to: url, atomically: true, encoding: .utf8)
  return url
}

/// Inserts an event whose detailJSON points at `transcriptURL`, plus a loose end citing
/// message index `citedIndex` with `quote`. Returns the inserted loose end.
private func seedLooseEnd(_ db: any DatabaseWriter, transcriptURL: URL,
                          citedIndex: Int, quote: String) throws -> LooseEnd {
  let (node, source) = try ProjectResolver(db: db).resolve(path: "/p/app", kind: SourceKind.claudeCode)
  let detail = try encodeJSON(["transcriptPath": transcriptURL.path, "sessionID": "s", "prompts": "2"])
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "session", detailJSON: detail, fingerprint: "fp")
  let le = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "finish the migration",
                    quote: quote, role: "user", sourceMessageIndex: citedIndex)
  try db.write { db in
    try Event.insert { event }.execute(db)
    try LooseEnd.insert { le }.execute(db)
  }
  return le
}

@Test func provenanceReturnsWindowAroundCitedUserPrompt() throws {
  let db = try openCanonicalDatabase(at: tempURL("prov-happy"))
  let url = try writeTranscript("prov-happy", [
    (type: "user", text: "hello there"),                                  // index 0
    (type: "assistant", text: "sure working on it"),                      // index 1
    (type: "user", text: "we still need to finish the migration"),        // index 2 (cited)
    (type: "assistant", text: "got it"),                                  // index 3
    (type: "user", text: "thanks"),                                       // index 4
  ])
  let le = try seedLooseEnd(db, transcriptURL: url, citedIndex: 2, quote: "finish the migration")

  let ctx = try ProvenanceQueries.context(db, looseEnd: le, radius: 1)
  #expect(ctx.transcriptAvailable)
  #expect(ctx.messages.map(\.index) == [1, 2, 3])          // radius 1 around index 2
  let cited = ctx.messages.first { $0.isCited }
  #expect(cited?.index == 2)
  #expect(cited?.text.contains("finish the migration") == true)
  #expect(cited?.isUserPrompt == true)
}

@Test func provenanceClampsWindowAtEdges() throws {
  let db = try openCanonicalDatabase(at: tempURL("prov-edge"))
  let url = try writeTranscript("prov-edge", [
    (type: "user", text: "start the work now"),                          // index 0 (cited)
    (type: "assistant", text: "ok"),                                     // index 1
  ])
  let le = try seedLooseEnd(db, transcriptURL: url, citedIndex: 0, quote: "start the work")
  let ctx = try ProvenanceQueries.context(db, looseEnd: le, radius: 4)
  #expect(ctx.transcriptAvailable)
  #expect(ctx.messages.map(\.index) == [0, 1])              // no negative indices
  #expect(ctx.messages.first?.isCited == true)
}

@Test func provenanceMissingTranscriptDegradesHonestly() throws {
  let db = try openCanonicalDatabase(at: tempURL("prov-missing"))
  let gone = tempURL("prov-missing-gone", ext: "jsonl")     // never written to disk
  let le = try seedLooseEnd(db, transcriptURL: gone, citedIndex: 0, quote: "anything")
  let ctx = try ProvenanceQueries.context(db, looseEnd: le, radius: 4)
  #expect(ctx.transcriptAvailable == false)
  #expect(ctx.messages.isEmpty)
}

@Test func provenanceRejectsOutOfBoundsIndex() throws {
  let db = try openCanonicalDatabase(at: tempURL("prov-oob"))
  let url = try writeTranscript("prov-oob", [(type: "user", text: "only message here")])
  let le = try seedLooseEnd(db, transcriptURL: url, citedIndex: 99, quote: "only message")
  let ctx = try ProvenanceQueries.context(db, looseEnd: le, radius: 4)
  #expect(ctx.transcriptAvailable == false)                 // no message with index 99
  #expect(ctx.messages.isEmpty)
}

@Test func provenanceRejectsSamePhraseNonUserFalseMatch() throws {
  // Index drift resolves sourceMessageIndex to a NON-user message that happens to contain the
  // quote. Requiring isUserPrompt on the cited message must reject it → honest fallback, never
  // a wrong highlight.
  let db = try openCanonicalDatabase(at: tempURL("prov-false"))
  let url = try writeTranscript("prov-false", [
    (type: "user", text: "please handle the retry logic"),               // index 0
    (type: "assistant", text: "handle the retry logic like this"),       // index 1 (non-user, same phrase)
  ])
  let le = try seedLooseEnd(db, transcriptURL: url, citedIndex: 1, quote: "handle the retry logic")
  let ctx = try ProvenanceQueries.context(db, looseEnd: le, radius: 2)
  #expect(ctx.transcriptAvailable == false)                 // cited message isUserPrompt == false → rejected
}
