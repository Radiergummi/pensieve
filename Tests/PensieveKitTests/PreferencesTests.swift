import Foundation
import Testing
@testable import PensieveKit

private func tempPrefsURL() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("pensieve-prefs-\(UUID().uuidString).json")
}

@Test func writeThenReadRoundTrips() {
  let url = tempPrefsURL()
  defer { try? FileManager.default.removeItem(at: url) }
  Preferences.write(.claudeCLI, to: url)
  #expect(Preferences.read(from: url) == .claudeCLI)
  Preferences.write(.foundationModels, to: url)
  #expect(Preferences.read(from: url) == .foundationModels)
}

@Test func missingFileReadsAsAuto() {
  let url = tempPrefsURL()   // never written
  #expect(Preferences.read(from: url) == .auto)
}

@Test func corruptFileReadsAsAuto() throws {
  let url = tempPrefsURL()
  defer { try? FileManager.default.removeItem(at: url) }
  try Data("not json".utf8).write(to: url)
  #expect(Preferences.read(from: url) == .auto)
}

@Test func unknownProviderValueReadsAsAuto() throws {
  let url = tempPrefsURL()
  defer { try? FileManager.default.removeItem(at: url) }
  try Data(#"{"llmProvider":"gpt5"}"#.utf8).write(to: url)
  #expect(Preferences.read(from: url) == .auto)
}

@Test func resolverAutoFollowsAvailability() {
  #expect(resolveProviderKind(preference: .auto, foundationAvailable: true) == "foundationModels")
  #expect(resolveProviderKind(preference: .auto, foundationAvailable: false) == "claudeCLI")
}

@Test func resolverForcedFoundationFallsBackWhenUnavailable() {
  #expect(resolveProviderKind(preference: .foundationModels, foundationAvailable: true) == "foundationModels")
  #expect(resolveProviderKind(preference: .foundationModels, foundationAvailable: false) == "claudeCLI")
}

@Test func resolverForcedClaudeAlwaysClaude() {
  #expect(resolveProviderKind(preference: .claudeCLI, foundationAvailable: true) == "claudeCLI")
  #expect(resolveProviderKind(preference: .claudeCLI, foundationAvailable: false) == "claudeCLI")
}

@Test func defaultProviderKindHonorsExplicitPrefsFile() throws {
  let url = tempPrefsURL()
  defer { try? FileManager.default.removeItem(at: url) }
  Preferences.write(.claudeCLI, to: url)
  #expect(defaultProviderKind(prefsURL: url) == "claudeCLI")
}
