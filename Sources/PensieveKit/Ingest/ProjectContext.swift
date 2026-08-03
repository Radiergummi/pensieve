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
    if let found = jsonNameDesc(worktree.appendingPathComponent("composer.json")) { return found }
    if let found = jsonNameDesc(worktree.appendingPathComponent("package.json")) { return found }
    if let found = grepFirst(worktree.appendingPathComponent("Package.swift"), pattern: #"name:\s*"([^"]+)""#) { return found }
    if let found = tomlNameDesc(worktree.appendingPathComponent("Cargo.toml")) { return found }
    if let found = tomlNameDesc(worktree.appendingPathComponent("pyproject.toml")) { return found }
    return nil
  }

  private static func jsonNameDesc(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: 65_536)) ?? Data()   // bound memory; a >64KB manifest is pathological
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
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
          let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
          let captureRange = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[captureRange])
  }

  /// Bounded UTF-8 head of a file: up to `maxBytes` and `maxLines`, trimmed. nil if absent,
  /// empty, or not decodable as UTF-8 (i.e. binary).
  private static func head(of url: URL, maxBytes: Int = 1024, maxLines: Int = 40) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
    guard !data.isEmpty else { return nil }
    // If we truncated at exactly maxBytes, a multi-byte character may straddle the cut — drop up
    // to 3 trailing bytes to recover valid text. A short read that still won't decode is binary.
    let decoded: String? = data.count == maxBytes
      ? (0...3).lazy.compactMap { String(data: data.dropLast($0), encoding: .utf8) }.first
      : String(data: data, encoding: .utf8)
    guard let text = decoded else { return nil }
    let joined = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines).joined(separator: "\n")
    let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// The signal lines shared by `namePrompt` and `describePrompt` — present fields only.
  private static func signalLines(_ ctx: ProjectContext) -> [String] {
    var lines = ["Directory name: \(ctx.dirName)"]
    if let remote = ctx.gitRemote { lines.append("Git remote: \(remote)") }
    if let manifest = ctx.manifest { lines.append("Package manifest: \(manifest)") }
    if let readme = ctx.readmeHead { lines.append("README excerpt:\n\(readme)") }
    if let claudeMd = ctx.claudeMdHead { lines.append("CLAUDE.md excerpt:\n\(claudeMd)") }
    return lines
  }

  /// Builds the naming prompt from the present signals only.
  static func namePrompt(_ ctx: ProjectContext) -> String {
    """
    Infer a concise, human-readable display name for this software project from the signals below. \
    Output only the name on a single line: 2-6 words, Title Case, a plain label — no numbering, \
    bullets, quotes, or trailing period. Prefer what the signals say; sensible formatting and \
    expanding an abbreviation the signals support is fine, but do not invent a category (like \
    "App", "CLI", or "Package") the signals do not support.

    \(signalLines(ctx).joined(separator: "\n"))
    """
  }

  /// Builds the "what is this project" prompt from the present signals only. Sibling to
  /// `namePrompt`; best-effort narration outside the trust gate.
  public static func describePrompt(_ ctx: ProjectContext) -> String {
    """
    Summarize what this software project IS in 1-2 sentences, from the signals below. Describe its \
    purpose or domain — not its recent activity or history. Output only the description as plain \
    prose: no heading, list markers, quotes, or code fences. Prefer what the signals say; do not \
    invent a purpose the signals do not support. If the signals are too thin to say anything, \
    output nothing.

    \(signalLines(ctx).joined(separator: "\n"))
    """
  }

  /// True when the gathered signals carry enough substance to describe — a manifest that includes
  /// a real description (`name — description`), or a README/CLAUDE.md whose body (past a leading
  /// title line) exceeds a small threshold. A bare dir name, a bare remote, a name-only manifest,
  /// or a one-line `# foo` README is NOT enough → the describe pass skips it (cheaply, no LLM) and
  /// retries once real content appears.
  public static func hasMeaningfulSignal(_ ctx: ProjectContext) -> Bool {
    if let manifest = ctx.manifest, manifest.contains(" — ") { return true }
    if descriptiveBodyLength(ctx.readmeHead) >= 20 { return true }
    if descriptiveBodyLength(ctx.claudeMdHead) >= 20 { return true }
    return false
  }

  /// Length of an excerpt's body after dropping a leading Markdown heading/title line and trimming.
  /// `# foo` → 0; `# App\nRow-level security…` → the body length. nil → 0.
  private static func descriptiveBodyLength(_ text: String?) -> Int {
    guard let text else { return 0 }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
      lines.removeFirst()
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).count
  }
}
