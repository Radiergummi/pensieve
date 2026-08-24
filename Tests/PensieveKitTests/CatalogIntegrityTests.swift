import Foundation
import Testing

// Sibling to `CatalogCoverageTests`, which asks whether catalog keys and Swift literals agree. This
// file asks the three questions that are invisible to that one and to every tool in the build:
//
// 1. Does a key appear TWICE in the file? JSON permits it and `JSONSerialization` silently keeps the
//    last, so a duplicate can sit in the catalog indefinitely with the losing copy edited forever
//    after and never rendered. Only a scan of the file text can see it.
// 2. Does every declared language actually have a translation for every translatable key? A missing
//    localization renders the source language, which is invisible to anyone testing in English.
// 3. Do `project.yml`'s three separate language declarations agree with each other? A language in
//    `knownRegions` but absent from a target's `CFBundleLocalizations` is compiled and then never
//    selected at runtime — the exact bug the comments beside those keys already warn about.
//
// The rules for reading `project.yml` and for counting keys as the file spells them live in
// `LocalizationRules.swift`, shared with `Tools/xcstrings` so there is one implementation of each.
//
// What this file deliberately does NOT check is canonical FORM — key order, or whether the source
// language's own unit is spelled out. That is the tool's business (`xcstrings fmt --check`), and
// restating the format rule here would be a second copy of it to drift.

// MARK: - Reading the catalog as JSON

/// One catalog entry, reduced to what these checks ask about. Everything else in the entry —
/// `comment`, `extractionState`, plural `variations` — is preserved by the tool and ignored here.
struct CatalogEntry {
  let key: String
  /// xcstrings' own opt-out, and the one this repo already uses for `·` and `%@`: a string that is
  /// punctuation or a bare interpolation has no copy to translate, and saying so in the catalog is
  /// better than saying it in a test allowlist the next translator will never read.
  let shouldTranslate: Bool
  let localizations: [String: [String: Any]]
}

func catalogEntries(at url: URL) throws -> (sourceLanguage: String, entries: [CatalogEntry]) {
  let root = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any] ?? [:]
  let strings = root["strings"] as? [String: Any] ?? [:]
  let entries = strings.map { key, value in
    let entry = value as? [String: Any] ?? [:]
    return CatalogEntry(
      key: key,
      shouldTranslate: entry["shouldTranslate"] as? Bool ?? true,
      localizations: (entry["localizations"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    )
  }
  return (root["sourceLanguage"] as? String ?? "", entries)
}

/// A state that counts as translated. `needs_review` is included on purpose: it is the declared,
/// reviewable form of "this is written but unverified", it survives in the file and in the diff, and
/// it is what a bulk import should land as. `new` is xcstrings' word for untranslated and is exactly
/// the gap this check exists to fail on.
private let satisfiedStates: Set<String> = ["translated", "needs_review"]

/// Whether a localization carries real text — following `variations` down to the leaves, since a
/// plural entry has no `stringUnit` of its own and every category must be filled to be usable.
func isTranslated(_ localization: [String: Any]) -> Bool {
  if let unit = localization["stringUnit"] as? [String: Any] {
    let state = unit["state"] as? String ?? ""
    let value = unit["value"] as? String ?? ""
    return satisfiedStates.contains(state) && !value.isEmpty
  }
  guard let variations = localization["variations"] as? [String: Any] else { return false }
  let leaves = variations.values.compactMap { $0 as? [String: Any] }.flatMap(\.values)
    .compactMap { $0 as? [String: Any] }
  return !leaves.isEmpty && leaves.allSatisfy(isTranslated)
}

private func projectYAML() throws -> String {
  try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"), encoding: .utf8)
}

// MARK: - The checks

@Test
func projectDeclaresTheSameLanguagesEverywhere() throws {
  let declarations = languageDeclarations(in: try projectYAML())

  // Guard the guard: this is an all-equal check over a list, and a list of zero or one is trivially
  // all-equal. A project.yml whose shape moved out from under the reader would pass silently.
  #expect(declarations.count >= 3, """
    read \(declarations.count) language declaration(s) from project.yml, expected at least three \
    (knownRegions plus one CFBundleLocalizations per bundled target) — the reader is broken, not the file
    """)
  #expect(declarations.allSatisfy { !$0.languages.isEmpty }, "a language declaration in project.yml is empty")

  let first = Set(declarations.first?.languages ?? [])
  let disagreeing = declarations.filter { Set($0.languages) != first }
  #expect(disagreeing.isEmpty, """
    project.yml declares different language sets: \
    \(declarations.map { "\($0.source)=\($0.languages.sorted())" }.joined(separator: ", ")). A language in \
    knownRegions but missing from a target's CFBundleLocalizations is compiled and then never selected at runtime.
    """)
}

@Test(arguments: catalogTargets)
func catalogHasNoDuplicateKeys(target: CatalogTarget) throws {
  let url = repositoryRoot.appendingPathComponent(target.catalog)
  let text = try String(contentsOf: url, encoding: .utf8)
  #expect(!rawCatalogKeys(inCatalogText: text).isEmpty, """
    \(target.name): the text scan found 0 keys in \(target.catalog) — the scanner is broken, not the catalog
    """)

  let duplicated = duplicatedCatalogKeys(inCatalogText: text)
  #expect(duplicated.isEmpty, """
    \(target.name): \(duplicated.count) key(s) appear more than once in \(target.catalog): \(duplicated). \
    JSON keeps the last of a duplicate pair, so the other copy renders nowhere no matter what is written into it.
    """)
}

@Test(arguments: catalogTargets)
func everyDeclaredLanguageTranslatesEveryKey(target: CatalogTarget) throws {
  let languages = Set(declaredLanguages(inProjectYAML: try projectYAML()))
  let (sourceLanguage, entries) = try catalogEntries(at: repositoryRoot.appendingPathComponent(target.catalog))

  #expect(!entries.isEmpty, """
    \(target.name): read 0 entries from \(target.catalog) — the catalog reader is broken, not the catalog
    """)
  #expect(languages.contains(sourceLanguage), """
    \(target.name): the catalog's sourceLanguage '\(sourceLanguage)' is not among project.yml's \
    knownRegions \(languages.sorted())
    """)
  // The source language needs no translation — its value is the key. Everything else does, and if
  // that leaves nothing to check, this test proves nothing and should say so rather than pass.
  let translationLanguages = languages.subtracting([sourceLanguage])
  #expect(!translationLanguages.isEmpty, "project.yml declares no language other than '\(sourceLanguage)' — this check is vacuous")

  let gaps = entries.filter(\.shouldTranslate).flatMap { entry in
    translationLanguages.sorted()
      .filter { !isTranslated(entry.localizations[$0] ?? [:]) }
      .map { "\($0): \"\(entry.key)\"" }
  }
  #expect(gaps.isEmpty, """
    \(target.name): \(gaps.count) key(s) are untranslated and will render \(sourceLanguage) under their own \
    locale. Translate them with `xcstrings set`, or mark the entry shouldTranslate:false if it is punctuation \
    with no copy: \(gaps.sorted().prefix(20).joined(separator: ", "))
    """)
}
