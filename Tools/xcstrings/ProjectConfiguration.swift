import Foundation

/// Walks up from the working directory until `project.yml` appears, so the tool works from anywhere
/// in the tree the way git does.
func findRepositoryRoot() throws -> URL {
  var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  while directory.path != "/" {
    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
      return directory
    }
    directory = directory.deletingLastPathComponent()
  }
  throw ToolError("no project.yml above \(FileManager.default.currentDirectoryPath) — run this inside the repo")
}

/// `project.yml`, which is where the supported languages are declared — three times over, as
/// `knownRegions` plus one `CFBundleLocalizations` per bundled target. Nothing here hard-codes a
/// language: the file is the authority, and adding one is a text edit to those same three lists.
struct ProjectConfiguration {
  let url: URL
  private(set) var text: String

  static func load(repositoryRoot: URL) throws -> ProjectConfiguration {
    let url = repositoryRoot.appendingPathComponent("project.yml")
    return ProjectConfiguration(url: url, text: try String(contentsOf: url, encoding: .utf8))
  }

  var languages: [String] { declaredLanguages(inProjectYAML: text) }

  /// Appends the language to every list that declares one, leaving the file otherwise byte-identical.
  /// A line edit rather than a YAML round trip on purpose: `project.yml` is hand-written and full of
  /// explanatory comments, and re-emitting it would lose every one of them.
  mutating func addLanguage(_ code: String) throws {
    let listNames: Set<String> = ["knownRegions", "CFBundleLocalizations"]
    let lines = text.components(separatedBy: .newlines)
    var output: [String] = []
    var index = 0
    var insertions = 0

    while index < lines.count {
      let line = lines[index]
      output.append(line)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasSuffix(":"), listNames.contains(String(trimmed.dropLast())) else {
        index += 1
        continue
      }
      let nameIndent = line.prefix { $0 == " " }.count
      index += 1

      var itemIndent: Int?
      var existing: [String] = []
      while index < lines.count {
        let entry = lines[index].trimmingCharacters(in: .whitespaces)
        let indent = lines[index].prefix { $0 == " " }.count
        guard entry.hasPrefix("- "), indent > nameIndent else { break }
        itemIndent = itemIndent ?? indent
        existing.append(String(entry.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        output.append(lines[index])
        index += 1
      }
      guard let itemIndent, !existing.contains(code) else { continue }
      output.append(String(repeating: " ", count: itemIndent) + "- " + code)
      insertions += 1
    }

    guard insertions > 0 else {
      throw ToolError("'\(code)' is already declared in every language list in project.yml")
    }
    text = output.joined(separator: "\n")
  }

  func save() throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
  }
}

/// Every String Catalog under `Sources/`, which is where both of this project's targets keep theirs.
func discoverCatalogs(repositoryRoot: URL) -> [URL] {
  let sources = repositoryRoot.appendingPathComponent("Sources")
  guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { return [] }
  return walker.compactMap { $0 as? URL }
    .filter { $0.pathExtension == "xcstrings" }
    .sorted { $0.path < $1.path }
}

/// Resolves `--catalog` against the discovered catalogs: a path if it is one, otherwise any unique
/// case-insensitive substring of one — `--catalog app` and `--catalog widget` both work, and neither
/// this tool nor its caller has to know the target names in advance.
func resolveCatalog(_ requested: String, repositoryRoot: URL) throws -> URL {
  let catalogs = discoverCatalogs(repositoryRoot: repositoryRoot)
  guard !catalogs.isEmpty else { throw ToolError("no .xcstrings found under Sources/") }
  if FileManager.default.fileExists(atPath: requested) { return URL(fileURLWithPath: requested) }

  let matches = catalogs.filter { $0.path.lowercased().contains(requested.lowercased()) }
  if matches.count == 1, let match = matches.first { return match }
  let available = catalogs.map { $0.lastPathComponent == requested ? $0.path : relative($0, to: repositoryRoot) }
  throw ToolError("""
    --catalog '\(requested)' \(matches.isEmpty ? "matched nothing" : "is ambiguous"). Available:
      \(available.joined(separator: "\n  "))
    """)
}

func relative(_ url: URL, to root: URL) -> String {
  url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.path
}
