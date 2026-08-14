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

  /// Garbage still degrades to off. The guard is now SHAPE rather than membership: `klingon` is not an
  /// ISO 639 subtag, so it never reaches the framework. Probed: `de`/`zh-Hans`/`pt-BR`/`de-DE` pass,
  /// `klingon` does not.
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

  /// The allow-list is gone, so a region- or script-qualified target the framework offers resolves to
  /// itself. `zh-HK` must NOT collapse to `zh`: the framework reports them as different languages
  /// (`zh-Hant-HK` vs `zh-Hans-CN`), and collapsing them would translate into the wrong script.
  @Test func regionQualifiedTargetsResolveToThemselves() {
    let hongKong = defaults("zh-hk")
    hongKong.set("zh-HK", forKey: PensieveDefaults.translationTargetKey)
    #expect(TranslationTarget.resolved(defaults: hongKong) == "zh-HK")

    let portugal = defaults("pt-pt")
    portugal.set("pt-PT", forKey: PensieveDefaults.translationTargetKey)
    #expect(TranslationTarget.resolved(defaults: portugal) == "pt-PT")
  }

  /// Display names must use `forIdentifier:`, not `forLanguageCode:`. Probed: the latter renders all
  /// three Chinese options as an identical "中文", making the picker unusable.
  @Test func displayNamesKeepTheirQualifier() {
    #expect(TranslationTarget.displayName(for: "de") == "Deutsch")
    #expect(TranslationTarget.displayName(for: "zh-HK") != TranslationTarget.displayName(for: "zh"))
  }

  /// An identifier Locale cannot name falls back to the identifier itself, so a row is never blank.
  @Test func anUnnameableIdentifierFallsBackToItself() {
    #expect(TranslationTarget.displayName(for: "zz-Zzzz") == "zz-Zzzz")
  }
}
