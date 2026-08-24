import Foundation

/// What every verb needs: the parsed command line, where the repo is, and the language list that
/// `project.yml` is the authority for.
struct CommandContext {
  let arguments: Arguments
  let repositoryRoot: URL
  var project: ProjectConfiguration

  var languages: [String] { project.languages }

  /// The catalogs a sweeping verb should visit: the one named, or all of them.
  func requestedCatalogs() throws -> [URL] {
    guard let requested = arguments.optional("catalog") else {
      return discoverCatalogs(repositoryRoot: repositoryRoot)
    }
    return [try resolveCatalog(requested, repositoryRoot: repositoryRoot)]
  }

  /// The one catalog a mutating verb must be told about explicitly — only the caller knows which
  /// target renders the literal, and guessing would put the key in a file that never shows it.
  func namedCatalog() throws -> StringCatalog {
    try loadCatalog(try resolveCatalog(try arguments.required("catalog"), repositoryRoot: repositoryRoot))
  }

  /// `--translation` and `--draft` together, which every writing verb accepts.
  func suppliedTranslations() throws -> [TranslationInput] {
    try arguments.translations(named: "translation", state: "translated")
      + arguments.translations(named: "draft", state: "needs_review")
  }

  /// Every mutation ends the same way: canonicalize, then write. The file is therefore always in
  /// canonical form after this tool touches it, and `fmt --check` only ever fails on a hand edit.
  func finish(_ catalog: inout StringCatalog, describing action: String) throws {
    catalog.canonicalize(declaredLanguages: Set(languages))
    try catalog.save()
    print("ok: \(action) in \(relative(catalog.url, to: repositoryRoot))")
    let gaps = untranslatedGaps(in: catalog, languages: languages)
    if !gaps.isEmpty { print("   still untranslated: \(gaps.joined(separator: ", "))") }
  }
}

/// Refuses a catalog that already contains a duplicate key, because everything past this point works
/// on the parsed tree — where the losing copy of that pair no longer exists. Writing it back out is
/// how you would delete a translation without ever seeing it happen.
func loadCatalog(_ url: URL) throws -> StringCatalog {
  let duplicates = duplicatedCatalogKeys(inCatalogText: try String(contentsOf: url, encoding: .utf8))
  guard duplicates.isEmpty else {
    throw ToolError("""
      \(url.lastPathComponent) contains \(duplicates.count) duplicate key(s): \(duplicates).
      Delete the copy you do not want by hand first — rewriting the file now would drop one silently.
      """)
  }
  return try StringCatalog.load(url)
}

/// `language (count)` for everything a declared language has not written yet.
func untranslatedGaps(in catalog: StringCatalog, languages: [String]) -> [String] {
  let satisfied: Set<String> = ["translated", "needs_review"]
  return languages.sorted().filter { $0 != catalog.sourceLanguage }.compactMap { language in
    let count = catalog.keys
      .filter { catalog.shouldTranslate(key: $0) }
      .filter { !satisfied.contains(catalog.state(key: $0, language: language) ?? "") }
      .count
    return count == 0 ? nil : "\(language) (\(count))"
  }
}

// MARK: - Writing verbs

func runAdd(_ context: CommandContext) throws {
  var catalog = try context.namedCatalog()
  let key = try context.arguments.required("key")
  let supplied = try context.suppliedTranslations()

  let missing = Set(context.languages).subtracting([catalog.sourceLanguage]).subtracting(supplied.map(\.language))
  guard missing.isEmpty else {
    throw ToolError("""
      no translation given for \(missing.sorted().joined(separator: ", ")). Pass --translation <lang>=<text> \
      for each, or --draft <lang>=<text> if the wording still needs checking.
      """)
  }
  try catalog.add(key: key, translations: supplied, comment: context.arguments.optional("comment"))
  try context.finish(&catalog, describing: "added \"\(key)\"")
}

func runSet(_ context: CommandContext) throws {
  var catalog = try context.namedCatalog()
  let key = try context.arguments.required("key")
  let supplied = try context.suppliedTranslations()
  guard !supplied.isEmpty else { throw ToolError("nothing to set — pass --translation or --draft") }
  try catalog.set(key: key, translations: supplied)
  try context.finish(&catalog, describing: "set \"\(key)\"")
}

func runRemove(_ context: CommandContext) throws {
  var catalog = try context.namedCatalog()
  let key = try context.arguments.required("key")
  try catalog.remove(key: key)
  try context.finish(&catalog, describing: "removed \"\(key)\"")
}

func runRename(_ context: CommandContext) throws {
  var catalog = try context.namedCatalog()
  let oldKey = try context.arguments.required("from")
  let newKey = try context.arguments.required("to")
  let followedKey = try catalog.rename(from: oldKey, to: newKey)
  try context.finish(&catalog, describing: "renamed \"\(oldKey)\" to \"\(newKey)\"")
  guard !followedKey else { return }
  let source = catalog.sourceLanguage
  print("""
       note: \(source) still renders its own value, because the key was an identifier rather than the \
    \(source) text. Pass --translation \(source)=<text> if that should change too.
    """)
}

func runAddLanguage(_ context: inout CommandContext) throws {
  guard let code = context.arguments.positional.first else {
    throw ToolError("usage: xcstrings add-language <code>")
  }
  try context.project.addLanguage(code)
  try context.project.save()
  print("ok: declared '\(code)' in \(relative(context.project.url, to: context.repositoryRoot))")

  for url in discoverCatalogs(repositoryRoot: context.repositoryRoot) {
    var catalog = try loadCatalog(url)
    let seeded = catalog.canonicalize(declaredLanguages: Set(context.languages))
    try catalog.save()
    print("   seeded \(seeded) entries in \(relative(url, to: context.repositoryRoot)) as \"\(untranslatedState)\"")
  }
  print("""
    project.yml and the catalogs now declare '\(code)'. The suite will fail until every seeded entry is \
    translated — that is the point. Work through them with `xcstrings audit`, then \
    `xcstrings set --catalog <name> --key <text> --translation \(code)=<text>`.
    """)
}

// MARK: - Reading verbs

/// Returns whether everything is in order, which is also this verb's exit status: `audit` is meant to
/// be usable as the last line of a verification run.
func runAudit(_ context: CommandContext) throws -> Bool {
  var healthy = true
  for url in try context.requestedCatalogs() {
    let text = try String(contentsOf: url, encoding: .utf8)
    let duplicates = duplicatedCatalogKeys(inCatalogText: text)
    let catalog = try StringCatalog.load(url)
    let translatable = catalog.keys.filter { catalog.shouldTranslate(key: $0) }

    print("\(relative(url, to: context.repositoryRoot))  (source: \(catalog.sourceLanguage))")
    print("  \(catalog.keys.count) keys, \(catalog.keys.count - translatable.count) not for translation")
    for language in context.languages.sorted() where language != catalog.sourceLanguage {
      let states = translatable.map { catalog.state(key: $0, language: language) }
      let translated = states.filter { $0 == "translated" }.count
      let review = states.filter { $0 == "needs_review" }.count
      let missing = states.filter { $0 == nil }.count
      print("""
          \(language): \(translated) translated, \(review) needs review, \
        \(states.count - translated - review - missing) untranslated, \(missing) missing
        """)
      if review + missing + (states.count - translated - review - missing) > 0 { healthy = false }
    }
    if !duplicates.isEmpty {
      print("  DUPLICATE KEYS: \(duplicates)")
      healthy = false
    }
    if text != catalog.canonicalText {
      print("  not in canonical form — run `xcstrings fmt`")
      healthy = false
    }
  }
  return healthy
}

/// Returns whether every catalog was already canonical.
func runFormat(_ context: CommandContext, checkOnly: Bool) throws -> Bool {
  var clean = true
  for url in try context.requestedCatalogs() {
    let original = try String(contentsOf: url, encoding: .utf8)
    var catalog = try loadCatalog(url)
    catalog.canonicalize(declaredLanguages: Set(context.languages))
    guard catalog.canonicalText != original else { continue }
    clean = false
    if checkOnly {
      print("not canonical: \(relative(url, to: context.repositoryRoot))")
    } else {
      try catalog.save()
      print("formatted: \(relative(url, to: context.repositoryRoot))")
    }
  }
  if clean { print(checkOnly ? "ok: every catalog is canonical" : "ok: nothing to format") }
  return clean
}
