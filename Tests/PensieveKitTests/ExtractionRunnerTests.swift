import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

private struct CannedProvider: LLMProvider {
  let json: String
  func complete(prompt: String) async throws -> String { json }
}

@Test func runnerStoresOnlyVerifiedLooseEnds() async throws {
  let db = try openCanonicalDatabase(at: tempURL("run-canon"))
  // A cc.session event pointing at the roles fixture (its cwd is /p/colibri).
  let url = Bundle.module.url(forResource: "session-roles", withExtension: "jsonl", subdirectory: "Fixtures")!
  let (project, source) = try ProjectResolver(db: db).resolve(path: "/p/colibri", kind: SourceKind.claudeCode)
  let detail = try encodeJSON(["sessionID": "session-roles", "prompts": "2", "transcriptPath": url.path])
  let event = Event(projectID: project.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: detail,
                    fingerprint: "fp-run")
  try await db.write { db in try Event.insert { event }.execute(db) }

  // Model proposes two: one real user quote, one fabricated → only the real one survives.
  let provider = CannedProvider(json: """
  [{"text":"add rate limiting","quote":"We still need to add rate limiting before launch","messageIndex":0},
   {"text":"call the bank","quote":"remember to call the bank tomorrow","messageIndex":0}]
  """)
  let results = try await ExtractionRunner(db: db, provider: provider).run()

  #expect(results.count == 1)
  #expect(results.first?.proposed == 2)
  #expect(results.first?.verified == 1)
  #expect(results.first?.inserted == 1)

  let ends = try await db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(ends.count == 1)
  #expect(ends.first?.quote == "We still need to add rate limiting before launch")
  #expect(ends.first?.role == "user")

  // extractedAt was set → a second run does nothing.
  let second = try await ExtractionRunner(db: db, provider: provider).run()
  #expect(second.isEmpty)
  #expect(try await db.read { db in try LooseEnd.all.fetchAll(db) }.count == 1)
}
