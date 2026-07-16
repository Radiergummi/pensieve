import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// A throwaway UserDefaults suite (no provider selection ⇒ .auto ⇒ a local kind).
private func throwawayDefaults() -> (UserDefaults, String) {
  let suite = "pensieve-test-\(UUID().uuidString)"
  return (UserDefaults(suiteName: suite)!, suite)
}

@Test func gatherReportsDisabledSyncAndEmptyStore() throws {
  let (d, suite) = throwawayDefaults()
  defer { d.removePersistentDomain(forName: suite) }
  let db = try openCanonicalDatabase(at: tempURL("status-empty"))

  let status = SystemStatusGatherer.gather(db: db, defaults: d,
                                           cloudConfig: nil, apiKey: nil,
                                           backgroundSyncEnabled: false,
                                           syncLogURL: tempURL("absent", ext: "log"))

  #expect(status.backgroundSyncEnabled == false)
  #expect(status.lastSyncAt == nil)
  #expect(status.lastEventAt == nil)                  // store has no events
  #expect(status.providerKind == "foundationModels" || status.providerKind == "claudeCLI")
  #expect(status.foundationModelsAvailable == FoundationModelsProbe.isAvailable())
}

@Test func gatherReportsEnabledSyncAndSyncLogMtime() throws {
  let (d, suite) = throwawayDefaults()
  defer { d.removePersistentDomain(forName: suite) }

  let log = tempURL("sync", ext: "log")
  try "ran".write(to: log, atomically: true, encoding: .utf8)

  let status = SystemStatusGatherer.gather(db: nil, defaults: d,
                                           cloudConfig: nil, apiKey: nil,
                                           backgroundSyncEnabled: true, syncLogURL: log)

  #expect(status.backgroundSyncEnabled == true)
  let mtime = try #require(status.lastSyncAt)
  #expect(abs(mtime.timeIntervalSinceNow) < 60)       // just written
  #expect(status.lastEventAt == nil)                  // nil db degrades, never throws
}

@Test func gatherReportsMostRecentEventTime() throws {
  let (d, suite) = throwawayDefaults()
  defer { d.removePersistentDomain(forName: suite) }
  let db = try openCanonicalDatabase(at: tempURL("status-events"))
  let resolver = ProjectResolver(db: db)
  let (node, source) = try resolver.resolve(path: "/p/one", kind: SourceKind.claudeCode)

  let old = Date(timeIntervalSince1970: 1_000_000)
  let newest = Date(timeIntervalSince1970: 2_000_000)
  try db.write { db in
    try Event.insert {
      Event(nodeID: node.id, sourceID: source.id, occurredAt: old, kind: CaptureKind.ccSession,
            summary: "old", detailJSON: "{}", fingerprint: "e1")
    }.execute(db)
    try Event.insert {
      Event(nodeID: node.id, sourceID: source.id, occurredAt: newest, kind: CaptureKind.ccSession,
            summary: "new", detailJSON: "{}", fingerprint: "e2")
    }.execute(db)
  }

  let status = SystemStatusGatherer.gather(db: db, defaults: d,
                                           cloudConfig: nil, apiKey: nil,
                                           backgroundSyncEnabled: false,
                                           syncLogURL: tempURL("absent", ext: "log"))

  let last = try #require(status.lastEventAt)
  #expect(abs(last.timeIntervalSince(newest)) < 1)    // the MAX, not the first row
}

@Test func gatherResolvesCloudKindWhenSelectedAndConfigured() throws {
  let (d, suite) = throwawayDefaults()
  defer { d.removePersistentDomain(forName: suite) }
  d.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  let config = CloudConfig(flavor: .anthropic,
                           baseURL: CloudFlavor.anthropic.defaultBaseURL,
                           model: "claude-sonnet-5")

  let configured = SystemStatusGatherer.gather(db: nil, defaults: d,
                                               cloudConfig: config, apiKey: "sk-test",
                                               backgroundSyncEnabled: false,
                                               syncLogURL: tempURL("absent", ext: "log"))
  #expect(configured.providerKind == "cloud")

  // Selected but keyless ⇒ falls back to a local kind (never "cloud"), same as the factory.
  let keyless = SystemStatusGatherer.gather(db: nil, defaults: d,
                                            cloudConfig: config, apiKey: nil,
                                            backgroundSyncEnabled: false,
                                            syncLogURL: tempURL("absent", ext: "log"))
  #expect(keyless.providerKind != "cloud")
}
