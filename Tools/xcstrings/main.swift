import Foundation

// xcstrings — the only thing that should ever write a String Catalog in this repo.
//
// The catalogs are hand-authored (SWIFT_EMIT_LOC_STRINGS and STRING_CATALOG_GENERATE_SYMBOLS are both
// off, deliberately — see project.yml), so nothing in the build maintains them and every edit used to
// be a hand-aimed substitution into 83 KB of JSON. This tool makes each edit one verb, keeps the file
// in a canonical shape so diffs stay readable, and refuses the two things a text edit does silently:
// dropping a duplicate key, and leaving a declared language with nothing to render.
//
// No language is named anywhere in this tool. project.yml's knownRegions is the authority.

let usage = """
usage: xcstrings <verb> [options]

  add     --catalog <name|path> --key <text> [--translation <lang>=<text>]... [--draft <lang>=<text>]... [--comment <text>]
  set     --catalog <name|path> --key <text> [--translation <lang>=<text>]... [--draft <lang>=<text>]...
  remove  --catalog <name|path> --key <text>
  rename  --catalog <name|path> --from <text> --to <text>

  add-language <code>          declare a language in project.yml and seed every catalog with it
  audit   [--catalog <name|path>]
  fmt     [--catalog <name|path>] [--check]

--translation writes state "translated"; --draft writes "needs_review" for text nobody has checked.
--catalog takes a path or any unique part of one, so `--catalog app` and `--catalog widget` both work.
"""

// MARK: - Arguments

struct Arguments {
  private var values: [String: [String]] = [:]
  private(set) var positional: [String] = []

  init(_ raw: [String]) {
    var index = 0
    while index < raw.count {
      let token = raw[index]
      guard token.hasPrefix("--") else {
        positional.append(token)
        index += 1
        continue
      }
      let name = String(token.dropFirst(2))
      let next = index + 1 < raw.count ? raw[index + 1] : nil
      if let next, !next.hasPrefix("--") {
        values[name, default: []].append(next)
        index += 2
      } else {
        values[name, default: []].append("")
        index += 1
      }
    }
  }

  func all(_ name: String) -> [String] { values[name] ?? [] }
  func optional(_ name: String) -> String? { values[name]?.last.flatMap { $0.isEmpty ? nil : $0 } }
  func has(_ name: String) -> Bool { values[name] != nil }

  func required(_ name: String) throws -> String {
    guard let value = optional(name) else { throw ToolError("missing --\(name)") }
    return value
  }

  /// `--translation de=Schließen`, split at the FIRST `=` so a translation may itself contain one.
  func translations(named name: String, state: String) throws -> [TranslationInput] {
    try all(name).map { pair in
      guard let separator = pair.firstIndex(of: "=") else {
        throw ToolError("--\(name) expects <lang>=<text>, got '\(pair)'")
      }
      let language = String(pair[pair.startIndex..<separator])
      let value = String(pair[pair.index(after: separator)...])
      guard !language.isEmpty, !value.isEmpty else {
        throw ToolError("--\(name) expects <lang>=<text>, got '\(pair)'")
      }
      return TranslationInput(language: language, value: value, state: state)
    }
  }
}

// MARK: - Entry point

func run() throws -> Int32 {
  var raw = Array(CommandLine.arguments.dropFirst())
  guard let verb = raw.first, !verb.hasPrefix("--") else { print(usage); return 2 }
  raw.removeFirst()

  let repositoryRoot = try findRepositoryRoot()
  var context = CommandContext(
    arguments: Arguments(raw),
    repositoryRoot: repositoryRoot,
    project: try ProjectConfiguration.load(repositoryRoot: repositoryRoot)
  )
  guard !context.languages.isEmpty else {
    throw ToolError("project.yml declares no knownRegions — the language list could not be read")
  }

  switch verb {
  case "add": try runAdd(context)
  case "set": try runSet(context)
  case "remove": try runRemove(context)
  case "rename": try runRename(context)
  case "add-language": try runAddLanguage(&context)
  case "audit": return try runAudit(context) ? 0 : 1
  case "fmt":
    let checkOnly = context.arguments.has("check")
    let clean = try runFormat(context, checkOnly: checkOnly)
    return checkOnly && !clean ? 1 : 0
  default:
    print(usage)
    return 2
  }
  return 0
}

do {
  exit(try run())
} catch let error as ToolError {
  FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
  exit(1)
} catch {
  FileHandle.standardError.write(Data("error: \(error)\n".utf8))
  exit(1)
}
