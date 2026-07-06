import Foundation

/// Cheap, best-effort local signals used to infer a human-readable project display name.
/// Every field is optional except `dirName`; a missing/unreadable/binary file is simply absent.
/// All reads are size-capped so the prompt stays small. Never throws.
public struct ProjectContext: Sendable {
  public var dirName: String
  public var gitRemote: String?
  public var readmeHead: String?
  public var claudeMdHead: String?
  public var manifest: String?

  public init(dirName: String, gitRemote: String?, readmeHead: String?,
              claudeMdHead: String?, manifest: String?) {
    self.dirName = dirName; self.gitRemote = gitRemote; self.readmeHead = readmeHead
    self.claudeMdHead = claudeMdHead; self.manifest = manifest
  }

  /// Gathers signals for the repo whose git common-dir is `commonDir` (the Source key).
  public static func gather(commonDir: String) -> ProjectContext {
    let dirName = ProjectResolver.displayName(forKey: commonDir)
    let worktree = workingTree(forCommonDir: commonDir)
    let remoteRepo = worktree?.path ?? commonDir
    let remote = Git.run(["remote", "get-url", "origin"], in: remoteRepo).flatMap { $0.isEmpty ? nil : $0 }
    guard let worktree else {
      return ProjectContext(dirName: dirName, gitRemote: remote,
                            readmeHead: nil, claudeMdHead: nil, manifest: nil)
    }
    return ProjectContext(dirName: dirName, gitRemote: remote,
                          readmeHead: readmeHead(in: worktree),
                          claudeMdHead: head(of: worktree.appendingPathComponent("CLAUDE.md")),
                          manifest: manifest(in: worktree))
  }

  /// The main working tree, or nil for bare/submodule/no-checkout layouts. The common-dir is the
  /// `.git` directory; its parent is the worktree, validated via `rev-parse --show-toplevel` run
  /// FROM the parent (running it from the common-dir itself fails — that's not a work tree). A
  /// common-dir not ending in `.git` (bare `foo.git`, submodule `.git/modules/<name>`) has none.
  private static func workingTree(forCommonDir commonDir: String) -> URL? {
    let url = URL(fileURLWithPath: commonDir)
    guard url.lastPathComponent == ".git" else { return nil }
    let parent = url.deletingLastPathComponent()
    guard let top = Git.run(["rev-parse", "--show-toplevel"], in: parent.path), !top.isEmpty else { return nil }
    return parent
  }

  /// First text README (`README`, `README.md`, `README.txt`, case-insensitive). Binary/other
  /// extensions (`README.pdf`, …) are skipped by construction.
  private static func readmeHead(in worktree: URL) -> String? {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: worktree.path) else { return nil }
    let names: Set<String> = ["readme", "readme.md", "readme.txt"]
    guard let match = entries.first(where: { names.contains($0.lowercased()) }) else { return nil }
    return head(of: worktree.appendingPathComponent(match))
  }

  /// First matching package manifest → a short `name — description` string (advisory, not
  /// authoritative). Order is fixed; a monorepo's arbitrary first match is acceptable.
  private static func manifest(in worktree: URL) -> String? {
    if let s = jsonNameDesc(worktree.appendingPathComponent("composer.json")) { return s }
    if let s = jsonNameDesc(worktree.appendingPathComponent("package.json")) { return s }
    if let s = grepFirst(worktree.appendingPathComponent("Package.swift"), pattern: #"name:\s*"([^"]+)""#) { return s }
    if let s = tomlNameDesc(worktree.appendingPathComponent("Cargo.toml")) { return s }
    if let s = tomlNameDesc(worktree.appendingPathComponent("pyproject.toml")) { return s }
    return nil
  }

  private static func jsonNameDesc(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return joinNameDesc(obj["name"] as? String, obj["description"] as? String)
  }

  private static func tomlNameDesc(_ url: URL) -> String? {
    let name = grepFirst(url, pattern: #"(?m)^\s*name\s*=\s*"([^"]+)""#)
    let desc = grepFirst(url, pattern: #"(?m)^\s*description\s*=\s*"([^"]+)""#)
    return joinNameDesc(name, desc)
  }

  private static func joinNameDesc(_ name: String?, _ desc: String?) -> String? {
    let parts = [name, desc].compactMap { $0 }.filter { !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    return String(parts.joined(separator: " — ").prefix(300))
  }

  /// First capture group of the first regex match in the file's head, or nil.
  private static func grepFirst(_ url: URL, pattern: String) -> String? {
    guard let text = head(of: url, maxBytes: 4096),
          let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
  }

  /// Bounded UTF-8 head of a file: up to `maxBytes` and `maxLines`, trimmed. nil if absent,
  /// empty, or not decodable as UTF-8 (i.e. binary).
  private static func head(of url: URL, maxBytes: Int = 1024, maxLines: Int = 40) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
    guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return nil }
    let joined = s.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines).joined(separator: "\n")
    let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Builds the naming prompt from the present signals only.
  static func namePrompt(_ ctx: ProjectContext) -> String {
    var lines = ["Directory name: \(ctx.dirName)"]
    if let r = ctx.gitRemote { lines.append("Git remote: \(r)") }
    if let m = ctx.manifest { lines.append("Package manifest: \(m)") }
    if let rd = ctx.readmeHead { lines.append("README excerpt:\n\(rd)") }
    if let cm = ctx.claudeMdHead { lines.append("CLAUDE.md excerpt:\n\(cm)") }
    return """
    Infer a concise, human-readable display name for this software project from the signals below. \
    Output only the name on a single line: 2-6 words, Title Case, a plain label — no numbering, \
    bullets, quotes, or trailing period. Prefer what the signals say; sensible formatting and \
    expanding an abbreviation the signals support is fine, but do not invent a category (like \
    "App", "CLI", or "Package") the signals do not support.

    \(lines.joined(separator: "\n"))
    """
  }
}
