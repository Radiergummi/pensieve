import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// Writes a minimal JSONL transcript and returns its URL. Mirrors the fixture in
/// `ProvenanceQueriesTests.swift`: type "user" prose -> isUserPrompt true; "assistant" -> false.
private func writeTranscript(_ prefix: String, _ lines: [(type: String, text: String)]) throws -> URL {
  let url = tempURL(prefix, ext: "jsonl")
  try writeTranscriptLines(lines, to: url)
  return url
}

/// Overwrites an already-created transcript file with new lines, in the same format as
/// `writeTranscript`. Used to simulate a live session growing between two loads.
private func writeTranscriptLines(_ lines: [(type: String, text: String)], to url: URL) throws {
  let jsonl = lines.map { line in
    #"{"type":"\#(line.type)","cwd":"/p/app","timestamp":"2026-06-29T13:03:43.382Z","# +
      #""message":{"role":"\#(line.type)","content":"\#(line.text)"}}"#
  }.joined(separator: "\n")
  try jsonl.write(to: url, atomically: true, encoding: .utf8)
}

/// Inserts a cc.session event whose detailJSON points at `transcriptURL` (the shape
/// `ProvenanceQueries.transcriptPath(in:)` decodes).
private func seedEvent(_ database: any DatabaseWriter, nodeID: UUID, sourceID: UUID,
                       transcriptURL: URL) throws -> Event {
  let detail = try encodeJSON(["transcriptPath": transcriptURL.path])
  let event = Event(nodeID: nodeID, sourceID: sourceID, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "session", detailJSON: detail)
  try database.write { database in try Event.insert { event }.execute(database) }
  return event
}

/// Inserts a loose end citing `messageIndex` of `event`'s transcript.
private func seedLooseEnd(_ database: any DatabaseWriter, nodeID: UUID, event: Event,
                          quote: String, messageIndex: Int) throws -> LooseEnd {
  let looseEnd = LooseEnd(nodeID: nodeID, sourceEventID: event.id, text: "an end", quote: quote,
                          role: "user", sourceMessageIndex: messageIndex)
  try database.write { database in try LooseEnd.insert { looseEnd }.execute(database) }
  return looseEnd
}

/// Concurrency-safe parse counter injected through `ProvenanceLoader`'s internal `parse` seam, so
/// tests can prove how many times a transcript file was actually parsed — vs served from cache or
/// rejected on a `stat` alone. Lock-protected (not a bare `var`): the closure is `@Sendable` and
/// called from inside the loader's actor, so a plain mutable capture would race under Swift 6.
private final class ParseCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

/// Wraps the real `TranscriptParser.parse` with `counter`, for injection into `ProvenanceLoader`'s
/// `init(database:cacheLimit:parse:)` seam.
private func countingParse(_ counter: ParseCounter) -> @Sendable (URL) -> ParsedSession {
  { url in
    counter.increment()
    return TranscriptParser.parse(fileURL: url)
  }
}

@Test func parsesOneTranscriptOnceForManyLooseEndsSharingIt() async throws {
  // The pre-existing waste this closes: three rows from one session parse that file three times.
  let database = try openCanonicalDatabase(at: tempURL("loader-shared"))
  let (node, source) = try ProjectResolver(database: database)
    .resolve(path: "/p/shared", kind: SourceKind.claudeCode)
  let transcript = try writeTranscript("loader-shared", [
    (type: "user", text: "fix the sync gap"),   // index 0 (cited by all three loose ends)
    (type: "assistant", text: "ok, looking"),   // index 1
  ])
  let event = try seedEvent(database, nodeID: node.id, sourceID: source.id, transcriptURL: transcript)
  let ends = try (0..<3).map { _ in
    try seedLooseEnd(database, nodeID: node.id, event: event, quote: "fix the sync gap", messageIndex: 0)
  }

  let counter = ParseCounter()
  let loader = ProvenanceLoader(database: database, cacheLimit: 200, parse: countingParse(counter))
  let loaded = await loader.load(all: ends, onProgress: { _, _ in })

  #expect(loaded.count == 3)
  // Mutation this catches: parsing per loose end instead of per unique path would read this file
  // three times, not once.
  #expect(counter.value == 1)
  #expect(loaded[ends[0].id]?.context.transcriptAvailable == true)
  // Mutation this catches: if `segments` were dropped, empty-filled, or derived from a different
  // pass than `context.messages`, the two arrays' counts would drift apart.
  #expect(loaded[ends[0].id]?.segments.count == loaded[ends[0].id]?.context.messages.count)
}

@Test func aSecondLoadOfTheSameLooseEndHitsTheCache() async throws {
  let database = try openCanonicalDatabase(at: tempURL("loader-cache-hit"))
  let (node, source) = try ProjectResolver(database: database)
    .resolve(path: "/p/cache-hit", kind: SourceKind.claudeCode)
  let transcript = try writeTranscript("loader-cache-hit", [
    (type: "user", text: "review the open pr"),   // index 0 (cited)
    (type: "assistant", text: "sure, on it"),      // index 1
  ])
  let event = try seedEvent(database, nodeID: node.id, sourceID: source.id, transcriptURL: transcript)
  let looseEnd = try seedLooseEnd(database, nodeID: node.id, event: event,
                                  quote: "review the open pr", messageIndex: 0)

  let counter = ParseCounter()
  let loader = ProvenanceLoader(database: database, cacheLimit: 200, parse: countingParse(counter))

  let first = await loader.load(looseEnd)
  #expect(first?.context.transcriptAvailable == true)
  #expect(counter.value == 1)

  let second = await loader.load(looseEnd)
  // Mutation this catches: a cache lookup that always misses (or is missing entirely) would
  // reparse an unchanged file here, and counter.value would read 2 instead of 1.
  #expect(counter.value == 1)
  #expect(second?.context.messages.map(\.index) == first?.context.messages.map(\.index))
  #expect(second?.segments.count == first?.segments.count)
}

@Test func aChangedTranscriptInvalidatesTheCachedEntry() async throws {
  // The case the spec's first draft got wrong: a LIVE session grows while the user sits on the
  // node. Invalidation is per-entry (size, mtime), not an app refresh signal.
  let database = try openCanonicalDatabase(at: tempURL("loader-invalidate"))
  let (node, source) = try ProjectResolver(database: database)
    .resolve(path: "/p/invalidate", kind: SourceKind.claudeCode)
  let transcript = try writeTranscript("loader-invalidate", [
    (type: "user", text: "fix the sync gap"),   // index 0 (cited)
    (type: "assistant", text: "ok"),            // index 1
    (type: "user", text: "thanks"),             // index 2
  ])
  let event = try seedEvent(database, nodeID: node.id, sourceID: source.id, transcriptURL: transcript)
  let looseEnd = try seedLooseEnd(database, nodeID: node.id, event: event,
                                  quote: "fix the sync gap", messageIndex: 0)

  let counter = ParseCounter()
  let loader = ProvenanceLoader(database: database, cacheLimit: 200, parse: countingParse(counter))

  let first = await loader.load(looseEnd)
  #expect(counter.value == 1)
  #expect(first?.context.messages.count == 3)   // default radius 4 clamps to the whole 3-message session

  // Grow the transcript in place (a live session appending turns), then force a distinguishable
  // fingerprint so the test doesn't depend on filesystem mtime resolution.
  try writeTranscriptLines([
    (type: "user", text: "fix the sync gap"),
    (type: "assistant", text: "ok"),
    (type: "user", text: "thanks"),
    (type: "assistant", text: "done"),
    (type: "user", text: "great, closing out"),
  ], to: transcript)
  try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)],
                                        ofItemAtPath: transcript.path)

  let second = await loader.load(looseEnd)
  // Mutation this catches: skipping the fingerprint check (or comparing only one of size/mtime in a
  // way that doesn't change here) would keep serving the stale 3-message window after the file grew,
  // and counter.value would stay at 1.
  #expect(counter.value == 2)
  #expect(second?.context.messages.count == 5)
}

@Test func aVanishedTranscriptIsRejectedWithoutParsing() async throws {
  // 24 of 37 referenced transcripts are gone on the measured store — they must cost a stat, not a
  // parse.
  let database = try openCanonicalDatabase(at: tempURL("loader-vanished"))
  let (node, source) = try ProjectResolver(database: database)
    .resolve(path: "/p/vanished", kind: SourceKind.claudeCode)
  let gone = tempURL("loader-vanished-gone", ext: "jsonl")   // never written to disk
  let event = try seedEvent(database, nodeID: node.id, sourceID: source.id, transcriptURL: gone)
  let looseEnd = try seedLooseEnd(database, nodeID: node.id, event: event, quote: "anything", messageIndex: 0)

  let counter = ParseCounter()
  let loader = ProvenanceLoader(database: database, cacheLimit: 200, parse: countingParse(counter))

  let loaded = await loader.load(looseEnd)
  #expect(loaded?.context.transcriptAvailable == false)
  #expect(loaded?.segments.isEmpty == true)
  // Mutation this catches: parsing before (or regardless of) checking existence would call `parse`
  // on a missing file; this pins that it never does.
  #expect(counter.value == 0)
}

@Test func theCacheIsBoundedByItsLimit() async throws {
  let database = try openCanonicalDatabase(at: tempURL("loader-bounded"))
  let (node, source) = try ProjectResolver(database: database)
    .resolve(path: "/p/bounded", kind: SourceKind.claudeCode)
  var ends: [LooseEnd] = []
  for index in 0..<3 {
    let transcript = try writeTranscript("loader-bounded-\(index)", [
      (type: "user", text: "task number \(index)"),
    ])
    let event = try seedEvent(database, nodeID: node.id, sourceID: source.id, transcriptURL: transcript)
    ends.append(try seedLooseEnd(database, nodeID: node.id, event: event,
                                 quote: "task number \(index)", messageIndex: 0))
  }

  let counter = ParseCounter()
  let loader = ProvenanceLoader(database: database, cacheLimit: 2, parse: countingParse(counter))

  let firstPass = await loader.load(all: ends, onProgress: { _, _ in })
  #expect(firstPass.count == 3)
  #expect(counter.value == 3)   // three distinct transcripts on the first pass, three parses

  let secondPass = await loader.load(all: ends, onProgress: { _, _ in })
  // Mutation this catches: no eviction (cache holds all three) would reparse zero here; the wrong
  // bound (or evicting everything) would reparse zero or three. A limit of 2 evicts exactly one of
  // the three entries, so reloading all three costs exactly one more parse.
  #expect(secondPass.count == 3)
  #expect(counter.value == 4)
}
