import Foundation

// SHARED SOURCE — compiled into two things.
//
//   1. the PensieveKitTests target, because it lives under Tests/ and SwiftPM takes it from there;
//   2. Tools/xcstrings, because the Makefile names this file on that tool's `swiftc` line.
//
// Both need the same two rules, and this repo has been bitten enough times by two implementations of
// one rule that a shared file is worth the oddity of its location. `CatalogIntegrityTests` asks
// "are there duplicate keys?" so it can fail the suite; `xcstrings` asks the same question so it can
// refuse to write — because JSONSerialization keeps the last of a duplicate pair, and a formatter
// that parsed and re-emitted such a file would silently delete the other copy.
//
// Nothing here may import Testing, XCTest or anything else the tool cannot link.

// MARK: - The declared languages

/// A list of scalars under a key, in the narrow YAML shape `project.yml` uses:
///
///     knownRegions:
///       - en
///       - de
///
/// Returned per occurrence, because the point of the agreement check is that there are several.
/// Deliberately not a YAML parser: this recognizes one shape and finds nothing when the file changes
/// shape, and "found nothing" is asserted against by the caller rather than passing quietly.
func yamlScalarLists(named name: String, in yaml: String) -> [[String]] {
  var lists: [[String]] = []
  let lines = yaml.components(separatedBy: .newlines)
  var index = 0
  while index < lines.count {
    guard lines[index].trimmingCharacters(in: .whitespaces) == "\(name):" else { index += 1; continue }
    let nameIndent = lines[index].prefix { $0 == " " }.count
    var values: [String] = []
    var cursor = index + 1
    while cursor < lines.count {
      let entry = lines[cursor].trimmingCharacters(in: .whitespaces)
      guard entry.hasPrefix("- "), lines[cursor].prefix(while: { $0 == " " }).count > nameIndent else { break }
      values.append(String(entry.dropFirst(2)).trimmingCharacters(in: .whitespaces))
      cursor += 1
    }
    lists.append(values)
    index = cursor
  }
  return lists
}

/// Every place `project.yml` names the supported languages, labelled for the failure message. There
/// are three: the project's `knownRegions`, and one `CFBundleLocalizations` per bundled target.
func languageDeclarations(in yaml: String) -> [(source: String, languages: [String])] {
  let regions = yamlScalarLists(named: "knownRegions", in: yaml)
    .map { (source: "knownRegions", languages: $0) }
  let bundles = yamlScalarLists(named: "CFBundleLocalizations", in: yaml).enumerated()
    .map { (source: "CFBundleLocalizations #\($0.offset + 1)", languages: $0.element) }
  return regions + bundles
}

/// The one authoritative language set. `knownRegions` is the answer rather than any catalog's own
/// contents, because a language nobody has translated a single string into yet exists in exactly one
/// place — here.
func declaredLanguages(inProjectYAML yaml: String) -> [String] {
  languageDeclarations(in: yaml).first { $0.source == "knownRegions" }?.languages ?? []
}

// MARK: - Reading a catalog as text

/// The keys of the `strings` object exactly as the FILE spells them, duplicates included — which is
/// the whole reason this exists instead of a call to `JSONSerialization`.
///
/// Tracks brace depth and skips over string contents, so that a `{`, a `}` or a `:` inside a
/// translation cannot be mistaken for structure.
func rawCatalogKeys(inCatalogText text: String) -> [String] {
  let characters = Array(text)
  var keys: [String] = []
  var depth = 0
  var stringsDepth: Int?
  var lastKey: String?
  var index = 0

  while index < characters.count {
    switch characters[index] {
    case "{", "[":
      depth += 1
      if lastKey == "strings", depth == 2 { stringsDepth = depth }
      lastKey = nil
      index += 1
    case "}", "]":
      if depth == stringsDepth { stringsDepth = nil }
      depth -= 1
      lastKey = nil
      index += 1
    case "\"":
      let scanned = scanString(characters, from: index)
      index = scanned.next
      guard let token = scanned.key else { lastKey = nil; continue }
      lastKey = token
      if depth == stringsDepth { keys.append(token) }
    default:
      index += 1
    }
  }
  return keys
}

/// The string beginning at `start`, reported as a key only when a colon follows it — and where
/// scanning resumes either way. Escapes are skipped whole so that a `\"` inside a translation does
/// not end the string early.
private func scanString(_ characters: [Character], from start: Int) -> (key: String?, next: Int) {
  var cursor = start + 1
  while cursor < characters.count, characters[cursor] != "\"" {
    cursor += characters[cursor] == "\\" ? 2 : 1
  }
  let token = String(characters[(start + 1)..<min(cursor, characters.count)])
  let afterQuote = min(cursor + 1, characters.count)

  var lookahead = afterQuote
  while lookahead < characters.count, characters[lookahead].isWhitespace { lookahead += 1 }
  guard lookahead < characters.count, characters[lookahead] == ":" else { return (nil, afterQuote) }
  return (token, lookahead + 1)
}

/// The keys that appear more than once, which is data loss waiting to happen in either direction.
func duplicatedCatalogKeys(inCatalogText text: String) -> [String] {
  let raw = rawCatalogKeys(inCatalogText: text)
  var counts: [String: Int] = [:]
  for key in raw { counts[key, default: 0] += 1 }
  return counts.filter { $0.value > 1 }.keys.sorted()
}
