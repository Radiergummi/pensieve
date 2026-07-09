import Foundation
import Testing
@testable import PensieveKit

// MARK: ProviderSettings.selection

@Test func selectionAbsentAndUnknownReadAsAuto() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  #expect(ProviderSettings.selection(from: d) == .auto)                 // absent
  d.set("bogus", forKey: PensieveDefaults.llmProviderKey)
  #expect(ProviderSettings.selection(from: d) == .auto)                 // unknown value
}

@Test func selectionReadsKnownValues() {
  let suite = "pensieve-test-\(UUID().uuidString)"
  let d = UserDefaults(suiteName: suite)!
  defer { d.removePersistentDomain(forName: suite) }
  for pref in [ProviderPreference.foundationModels, .claudeCLI, .cloud, .auto] {
    d.set(pref.rawValue, forKey: PensieveDefaults.llmProviderKey)
    #expect(ProviderSettings.selection(from: d) == pref)
  }
}

// MARK: resolveProviderKind

@Test func resolverAutoFollowsAvailability() {
  #expect(resolveProviderKind(preference: .auto, foundationAvailable: true, cloudConfigured: false) == "foundationModels")
  #expect(resolveProviderKind(preference: .auto, foundationAvailable: false, cloudConfigured: false) == "claudeCLI")
}

@Test func resolverForcedFoundationFallsBackWhenUnavailable() {
  #expect(resolveProviderKind(preference: .foundationModels, foundationAvailable: true, cloudConfigured: false) == "foundationModels")
  #expect(resolveProviderKind(preference: .foundationModels, foundationAvailable: false, cloudConfigured: false) == "claudeCLI")
}

@Test func resolverForcedClaudeAlwaysClaude() {
  #expect(resolveProviderKind(preference: .claudeCLI, foundationAvailable: true, cloudConfigured: false) == "claudeCLI")
  #expect(resolveProviderKind(preference: .claudeCLI, foundationAvailable: false, cloudConfigured: false) == "claudeCLI")
}

@Test func resolverCloudRequiresConfiguredElseLocal() {
  #expect(resolveProviderKind(preference: .cloud, foundationAvailable: false, cloudConfigured: true) == "cloud")
  #expect(resolveProviderKind(preference: .cloud, foundationAvailable: true, cloudConfigured: false) == "foundationModels")
  #expect(resolveProviderKind(preference: .cloud, foundationAvailable: false, cloudConfigured: false) == "claudeCLI")
}
