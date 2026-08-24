import Foundation

struct ToolError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// A translation as the caller supplied it on the command line.
struct TranslationInput {
  let language: String
  let value: String
  /// `translated` from `--translation`, `needs_review` from `--draft`. Both satisfy the catalog
  /// integrity tests; `needs_review` is the honest one for text nobody has checked yet.
  let state: String
}

/// xcstrings' own word for untranslated. Seeded by `add-language`, and deliberately a state the test
/// suite fails on: a new language starts red and goes green as it is filled in.
let untranslatedState = "new"

struct StringCatalog {
  let url: URL
  private var root: [String: JSONValue]

  var sourceLanguage: String { root["sourceLanguage"]?.asString ?? "en" }
  var keys: [String] { Array(strings.keys) }

  private var strings: [String: JSONValue] {
    get { root["strings"]?.asObject ?? [:] }
    set { root["strings"] = .object(newValue) }
  }

  static func load(_ url: URL) throws -> StringCatalog {
    let data = try Data(contentsOf: url)
    guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ToolError("\(url.lastPathComponent): not a JSON object")
    }
    guard case .object(let object) = JSONValue.from(parsed) else {
      throw ToolError("\(url.lastPathComponent): not a JSON object")
    }
    return StringCatalog(url: url, root: object)
  }

  /// Rendered without a trailing newline, which is how Xcode writes this file. Adding one would show
  /// up as a diff on every catalog the first time any other tool touched it.
  var canonicalText: String { JSONValue.object(root).rendered() }

  func save() throws {
    try canonicalText.write(to: url, atomically: true, encoding: .utf8)
  }

  // MARK: - Reading

  func contains(key: String) -> Bool { strings[key] != nil }

  /// `false` only where the catalog says so. A string that is punctuation or a bare interpolation
  /// has no copy to translate, and `shouldTranslate: false` is xcstrings' way of recording that.
  func shouldTranslate(key: String) -> Bool {
    strings[key]?.asObject?["shouldTranslate"]?.asBool ?? true
  }

  /// The state of one language's unit, or nil when the language is absent entirely. Follows
  /// `variations` to its leaves and reports the weakest state found, since a plural is only as
  /// translated as its least-translated category.
  func state(key: String, language: String) -> String? {
    guard let localization = strings[key]?.asObject?["localizations"]?.asObject?[language]?.asObject
    else { return nil }
    return weakestState(in: localization)
  }

  private func weakestState(in localization: [String: JSONValue]) -> String? {
    if let unit = localization["stringUnit"]?.asObject {
      guard let value = unit["value"]?.asString, !value.isEmpty else { return untranslatedState }
      return unit["state"]?.asString ?? untranslatedState
    }
    guard let variations = localization["variations"]?.asObject else { return untranslatedState }
    let leaves = variations.values
      .compactMap(\.asObject).flatMap(\.values)
      .compactMap(\.asObject)
    guard !leaves.isEmpty else { return untranslatedState }
    let states = leaves.compactMap(weakestState(in:))
    if states.contains(untranslatedState) { return untranslatedState }
    return states.contains("needs_review") ? "needs_review" : states.first
  }

  // MARK: - Writing

  mutating func add(key: String, translations: [TranslationInput], comment: String?) throws {
    guard !contains(key: key) else {
      throw ToolError("\"\(key)\" is already in \(url.lastPathComponent) — use `set` to change its translations")
    }
    var entry: [String: JSONValue] = ["extractionState": .string("manual")]
    if let comment { entry["comment"] = .string(comment) }
    entry["localizations"] = .object([sourceLanguage: unit(value: key, state: "translated")])
    strings[key] = .object(entry)
    try set(key: key, translations: translations)
  }

  mutating func set(key: String, translations: [TranslationInput]) throws {
    guard var entry = strings[key]?.asObject else {
      throw ToolError("\"\(key)\" is not in \(url.lastPathComponent)")
    }
    var localizations = entry["localizations"]?.asObject ?? [:]
    for translation in translations {
      if localizations[translation.language]?.asObject?["variations"] != nil {
        throw ToolError("""
          \"\(key)\" is a plural entry in \(translation.language) — its categories cannot be set from the \
          command line. Edit the variations block directly, then run `xcstrings fmt`.
          """)
      }
      localizations[translation.language] = unit(value: translation.value, state: translation.state)
    }
    entry["localizations"] = .object(localizations)
    strings[key] = .object(entry)
  }

  mutating func remove(key: String) throws {
    guard contains(key: key) else { throw ToolError("\"\(key)\" is not in \(url.lastPathComponent)") }
    strings[key] = nil
  }

  /// Carries the translations across, and follows the key with the source-language value — the two
  /// normally agree, and a rename that updated one and not the other is the classic way this file
  /// breaks.
  ///
  /// "Normally", because a handful of keys here are identifiers rather than English text: `Loose end
  /// done` renders as "Done". Rewriting those to match the key would silently change what the app
  /// says, so the source value follows the key only when it WAS the key. Returns whether it did.
  @discardableResult
  mutating func rename(from oldKey: String, to newKey: String) throws -> Bool {
    guard let existing = strings[oldKey]?.asObject else {
      throw ToolError("\"\(oldKey)\" is not in \(url.lastPathComponent)")
    }
    guard !contains(key: newKey) else {
      throw ToolError("\"\(newKey)\" is already in \(url.lastPathComponent)")
    }
    var entry = existing
    var localizations = entry["localizations"]?.asObject ?? [:]
    let sourceValue = localizations[sourceLanguage]?.asObject?["stringUnit"]?.asObject?["value"]?.asString
    let followsKey = sourceValue == oldKey
    if followsKey {
      localizations[sourceLanguage] = unit(value: newKey, state: "translated")
    }
    entry["localizations"] = .object(localizations)
    strings[oldKey] = nil
    strings[newKey] = .object(entry)
    return followsKey
  }

  /// Canonical form: every translatable entry carries an explicit unit for every declared language.
  /// A language with nothing written for it yet lands as `state: "new"` with the source text as a
  /// placeholder — present in the file, visible in the diff, and failed by the integrity tests until
  /// someone translates it. Returns the number of entries it changed.
  @discardableResult
  mutating func canonicalize(declaredLanguages: Set<String>) -> Int {
    var changed = 0
    for key in keys where shouldTranslate(key: key) {
      guard var entry = strings[key]?.asObject else { continue }
      var localizations = entry["localizations"]?.asObject ?? [:]
      var touched = false
      for language in declaredLanguages where localizations[language] == nil {
        let isSource = language == sourceLanguage
        localizations[language] = unit(value: key, state: isSource ? "translated" : untranslatedState)
        touched = true
      }
      guard touched else { continue }
      entry["localizations"] = .object(localizations)
      strings[key] = .object(entry)
      changed += 1
    }
    return changed
  }

  private func unit(value: String, state: String) -> JSONValue {
    .object(["stringUnit": .object(["state": .string(state), "value": .string(value)])])
  }
}
