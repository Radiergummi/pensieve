// Tests/PensieveKitTests/TranslationTargetTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Suite struct TranslationTargetTests {
  /// A fresh suite name per test: these run in parallel with everything else, and a shared domain
  /// would race.
  private func defaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: "pensieve.tests.translation.\(name)")!
    defaults.removePersistentDomain(forName: "pensieve.tests.translation.\(name)")
    return defaults
  }

  /// Off is the default, and off must mean off — no store, no index rows, no model load. The vector
  /// engine shipped "default-off" that a stale persisted `true` silently overrode; this pins that an
  /// unset value reads as off rather than as a language.
  @Test func unsetResolvesToOff() {
    #expect(TranslationTarget.resolved(defaults: defaults("unset")) == TranslationTarget.off)
    #expect(TranslationTarget.off.isEmpty)
  }

  @Test func aSupportedLanguageResolvesToItself() {
    let store = defaults("supported")
    store.set("de", forKey: PensieveDefaults.translationTargetKey)
    #expect(TranslationTarget.resolved(defaults: store) == "de")
  }

  /// An unsupported or garbage persisted value degrades to off rather than being handed to the
  /// framework, which would fail per call and log on every render.
  @Test func anUnsupportedLanguageResolvesToOff() {
    let store = defaults("unsupported")
    store.set("klingon", forKey: PensieveDefaults.translationTargetKey)
    #expect(TranslationTarget.resolved(defaults: store) == TranslationTarget.off)
  }

  /// English is the source, never a target: translating en→en is a no-op that would still cost a
  /// store write and an index row per item.
  @Test func englishResolvesToOff() {
    let store = defaults("english")
    store.set("en", forKey: PensieveDefaults.translationTargetKey)
    #expect(TranslationTarget.resolved(defaults: store) == TranslationTarget.off)
  }
}
