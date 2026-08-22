import Foundation
import Testing

/// Guards the rule CLAUDE.md states and this repo keeps paying for: a String Catalog key must match
/// its Swift literal character-for-character, or the German silently falls back to English. Nothing
/// warns — not the compiler, not `xcodebuild`, which does not extract keys at all. The widget's
/// gallery description shipped English-only for exactly this reason.
///
/// Both directions are checked, because they fail differently. A literal with no key renders English
/// under a German locale; a key with no literal is dead weight that makes the catalog look like it
/// covers more than it does. Neither is visible to anyone testing in English.
///
/// Lives in PensieveKitTests rather than a script so `make test` enforces it with no new build target
/// — and in Swift, because this repo does not do Python.
private let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A localizable literal and a catalog key are compared as SHAPES: every interpolation on one side
/// and every format specifier on the other collapses to this sentinel. `\(count)` becomes `%lld` and
/// `\(node.name)` becomes `%@`, and which one is a matter of the interpolated TYPE — knowable to the
/// compiler, not to a source scan. Comparing shapes sidesteps that without weakening anything else:
/// the surrounding characters still have to agree exactly.
private let placeholder = "\u{1}"

private func shape(catalogKey key: String) -> String {
  var out = key
  for specifier in ["%lld", "%lf", "%@", "%d", "%f"] {
    out = out.replacingOccurrences(of: specifier, with: placeholder)
  }
  return out
}

// MARK: - Which literals are localizable

/// The call sites whose string argument is localized. Deliberately a list rather than "every string
/// literal": most literals in this codebase are dictionary keys, log messages and SQL, none of which
/// belong in a catalog. An initializer missing from this list surfaces as a false DEAD key rather
/// than silently passing, which is the safe direction to be wrong in.
private let localizingContexts = [
  "Text", "Label", "Button", "Toggle", "Picker", "Section", "Link", "Menu", "Stepper",
  "TextField", "SecureField", "ContentUnavailableView", "LocalizedStringKey",
  "LocalizedStringResource", "LocalizationValue",
]
private let localizingLabels = ["localized", "titleKey", "title", "prompt", "header", "footer"]
private let localizingModifiers = [
  "help", "navigationTitle", "navigationSubtitle", "accessibilityLabel", "confirmationDialog",
  "alert", "searchable",
]
/// `static let title: LocalizedStringResource = "…"` — an App Intent declares its chrome this way,
/// with the literal assigned to a localized TYPE rather than passed to any initializer.
private let localizingTypes = ["LocalizedStringResource", "LocalizedStringKey"]

private func isLocalizingSite(_ before: Substring) -> Bool {
  let tail = String(before.suffix(80))
  if localizingContexts.contains(where: { tail.hasSuffix("\($0)(") }) { return true }
  if localizingModifiers.contains(where: { tail.hasSuffix(".\($0)(") }) { return true }
  if localizingTypes.contains(where: { tail.hasSuffix(": \($0) = ") }) { return true }
  return localizingLabels.contains { tail.hasSuffix("\($0): ") || tail.hasSuffix("\($0):") }
}

// MARK: - Reading Swift string literals

/// Hand-written rather than regex because the literals that matter here defeat one: interpolations
/// nest parentheses and can themselves contain quotes (`\(x, format: .foo("bar"))`), and the delete
/// confirmation is a multi-line literal joined by trailing backslashes. A regex got all three wrong.
private struct LiteralScanner {
  let characters: [Character]

  /// Past a `\(…)` interpolation, including any string literals nested inside it.
  func endOfInterpolation(from start: Int) -> Int {
    var cursor = start, depth = 0
    while cursor < characters.count {
      switch characters[cursor] {
      case "(": depth += 1
      case ")": depth -= 1; if depth == 0 { return cursor + 1 }
      case "\"":
        cursor += 1
        while cursor < characters.count, characters[cursor] != "\"" {
          cursor += characters[cursor] == "\\" ? 2 : 1
        }
      default: break
      }
      cursor += 1
    }
    return cursor
  }

  /// An escape sequence's contribution to the literal's value, and where scanning resumes.
  func escape(at index: Int) -> (text: String, next: Int) {
    let escaped = characters[index + 1]
    if escaped == "(" { return (placeholder, endOfInterpolation(from: index + 1)) }
    if escaped == "\n" {
      // A continuation joins two source lines; the indentation that follows is layout, not copy.
      var cursor = index + 2
      while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
      return ("", cursor)
    }
    return (escaped == "n" ? "\n" : String(escaped), index + 2)
  }

  /// The literal beginning at `start` (already past its opening quote), and where it ends.
  func literal(from start: Int, isMultiline: Bool) -> (value: String, next: Int) {
    var index = start, value = ""
    while index < characters.count {
      if characters[index] == "\\", index + 1 < characters.count {
        let (text, next) = escape(at: index)
        value += text
        index = next
        continue
      }
      if characters[index] == "\"" {
        guard isMultiline else { return (value, index + 1) }
        if index + 2 < characters.count, characters[index + 1] == "\"", characters[index + 2] == "\"" {
          return (value, index + 3)
        }
      }
      if !isMultiline, characters[index] == "\n" { return (value, index) }   // unterminated
      value.append(characters[index])
      index += 1
    }
    return (value, index)
  }
}

/// Every string literal in `source`, paired with the text preceding it.
private func literals(in source: String) -> [(before: Substring, value: String)] {
  let scanner = LiteralScanner(characters: Array(source))
  var results: [(Substring, String)] = []
  var index = 0
  while index < scanner.characters.count {
    guard scanner.characters[index] == "\"" else { index += 1; continue }
    let start = index
    let isMultiline = index + 2 < scanner.characters.count
      && scanner.characters[index + 1] == "\"" && scanner.characters[index + 2] == "\""
    let (value, next) = scanner.literal(from: index + (isMultiline ? 3 : 1), isMultiline: isMultiline)
    results.append((source.prefix(start), isMultiline ? collapsed(value) : value))
    index = next
  }
  return results
}

/// A multi-line literal as the catalog stores it: one line, indentation dropped.
private func collapsed(_ value: String) -> String {
  value.split(separator: "\n", omittingEmptySubsequences: false)
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .joined(separator: " ")
    .trimmingCharacters(in: .whitespaces)
}

// MARK: - Gathering

private func swiftFiles(under directory: URL) -> [URL] {
  guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
  else { return [] }
  return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

private func catalogKeys(at url: URL) throws -> Set<String> {
  let root = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
  return Set((root?["strings"] as? [String: Any] ?? [:]).keys)
}

/// Every literal in the target's sources, localizable or not. The DEAD-key direction uses this
/// rather than the localizing-site filter: a key whose text appears nowhere is dead beyond argument,
/// while one built by a runtime mapping (`NodeContext.displayKey`, the provider and node-kind names)
/// is perfectly alive and simply not attributable to a call site. Judging those two apart by call
/// site produced 37 false positives; judging by presence produces none.
private func allLiteralShapes(inSourcesUnder directory: URL) -> Set<String> {
  var shapes: Set<String> = []
  for file in swiftFiles(under: directory) {
    guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
    for (_, value) in literals(in: source) where !value.isEmpty { shapes.insert(value) }
  }
  return shapes
}

private func localizedShapes(inSourcesUnder directory: URL) -> Set<String> {
  var shapes: Set<String> = []
  for file in swiftFiles(under: directory) {
    guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
    // A shape with no letters is punctuation or bare interpolation — "…", "\(a)\(b)" — and has no
    // copy to translate. Requiring a catalog entry for those would be noise, not coverage.
    for (before, value) in literals(in: source)
    where isLocalizingSite(before) && value.contains(where: \.isLetter) {
      shapes.insert(value)
    }
  }
  return shapes
}

// MARK: - The checks

/// Internal, not private: Swift Testing's `arguments:` puts the type in the test function's
/// signature, and a private type there is a compile error.
struct CatalogTarget: Sendable {
  let name: String
  let sources: String
  let catalog: String
  /// Keys deliberately in the catalog with no literal, or literals deliberately uncatalogued. Each
  /// needs a reason — an allowlist without one becomes the place findings go to be forgotten.
  let allowedDeadKeys: Set<String>
  let allowedMissingKeys: Set<String>
}

private let targets = [
  CatalogTarget(name: "PensieveApp", sources: "Sources/PensieveApp",
         catalog: "Sources/PensieveApp/Localizable.xcstrings",
         allowedDeadKeys: [],
         // "Briefing" is an established German loanword; leaving it untranslated reads naturally.
         allowedMissingKeys: ["Briefing"]),
  CatalogTarget(name: "PensieveWidget", sources: "Sources/PensieveWidget",
         catalog: "Sources/PensieveWidget/Localizable.xcstrings",
         allowedDeadKeys: [], allowedMissingKeys: []),
]

@Test(arguments: targets)
func everyCatalogKeyIsRenderedBySomeLiteral(target: CatalogTarget) throws {
  let keys = try catalogKeys(at: repositoryRoot.appendingPathComponent(target.catalog))
  // PensieveKit counts too: it is linked by both targets and supplies keys they render through a
  // runtime lookup (`NodeContext.displayKey`), so its literals are this target's literals.
  let present = allLiteralShapes(inSourcesUnder: repositoryRoot.appendingPathComponent(target.sources))
    .union(allLiteralShapes(inSourcesUnder: repositoryRoot.appendingPathComponent("Sources/PensieveKit")))
  let dead = Set(keys.map(shape(catalogKey:))).subtracting(present)
    .subtracting(target.allowedDeadKeys.map(shape(catalogKey:)))
  #expect(dead.isEmpty, """
    \(target.name): \(dead.count) catalog key(s) render nowhere — delete them, or add to \
    allowedDeadKeys with a reason: \(dead.sorted())
    """)
}

@Test(arguments: targets)
func everyRenderedLiteralHasACatalogKey(target: CatalogTarget) throws {
  let keys = try catalogKeys(at: repositoryRoot.appendingPathComponent(target.catalog))
  let rendered = localizedShapes(inSourcesUnder: repositoryRoot.appendingPathComponent(target.sources))
  let missing = rendered.subtracting(keys.map(shape(catalogKey:)))
    .subtracting(target.allowedMissingKeys)
  #expect(missing.isEmpty, """
    \(target.name): \(missing.count) literal(s) have no catalog key and will render English under \
    every locale: \(missing.sorted())
    """)
}
