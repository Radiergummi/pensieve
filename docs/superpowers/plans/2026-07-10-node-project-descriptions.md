# Node Project Descriptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Populate the currently-empty `Node.description` for git-backed project nodes with a concise, README/CLAUDE.md/manifest-derived "what this project is" summary, generated best-effort on-device, plus an on-demand refresh button in the app.

**Architecture:** Reuse the existing `ProjectContext.gather(commonDir:)` signal collector — today it only feeds the *name* prompt — by adding a sibling `describePrompt`. A new `NodeDescriber` unit turns (node → its single git source → gathered signals → LLM → sanitized prose) into a written `description`, returning a typed `Outcome`. The daemon runs a capped `Ingester.describeProjectNodes()` pass (wired into `SyncRunner.run()`, next to `refineProjectNames()`); the app's DetailView button calls the same `NodeDescriber` via `AppModel.describeNode`. A non-empty `description` is itself the "done" state — no metadata marker — so a repo that gains a README later gets described on a later cycle.

**Tech Stack:** Swift 6, SQLiteData (GRDB), Swift Testing (`@Test`/`#expect`), SwiftUI (app target), XcodeGen + Xcode for the app bundle.

## Global Constraints

- **SQLiteData predicates use `.eq(x)`, NOT `== x`** (e.g. `$0.kind.eq(NodeKind.project)`).
- Kind/source strings come from `NodeKind` / `SourceKind` constants — never hardcode `"project"` / `"gitRepo"`.
- No Python. Swift only.
- Descriptions are **best-effort, outside the strict cited trust gate** — like strand naming and "Last Work Done" narration. Never block or throw into a capture/ingest path.
- **PensieveKit is tested** (`./scripts/test.sh`); the **app target has no unit tests** — verify app tasks with an `xcodebuild` build + a non-blocking smoke-launch of the inner binary (`./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`) with throwaway `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB`.
- Localize **app chrome only** (English base + German `de`). Description **content** is never localized. Hand-edit `Localizable.xcstrings` (xcodebuild does not auto-populate keys); a `de` value only "counts" when `state: "translated"`.
- **`Localizable.xcstrings` may carry concurrent uncommitted user edits** — add new keys without disturbing existing entries; stage only the keys you added.
- German tone: impersonal / infinitive.

---

### Task 1: `ProjectContext.describePrompt` + `hasMeaningfulSignal`

Add the description prompt (sibling to `namePrompt`) and the substance predicate that decides whether a repo has enough to describe. Both are pure functions over an already-gathered `ProjectContext`.

**Files:**
- Modify: `Sources/PensieveKit/Ingest/ProjectContext.swift`
- Test: `Tests/PensieveKitTests/ProjectContextTests.swift` (existing — append)

**Interfaces:**
- Consumes: existing `ProjectContext` struct (fields `dirName`, `gitRemote`, `readmeHead`, `claudeMdHead`, `manifest`) and its `public init`.
- Produces:
  - `static func describePrompt(_ ctx: ProjectContext) -> String`
  - `static func hasMeaningfulSignal(_ ctx: ProjectContext) -> Bool`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/ProjectContextTests.swift`:

```swift
// MARK: describePrompt

@Test func describePromptIncludesOnlyPresentSignals() {
  let ctx = ProjectContext(dirName: "laravel-rls", gitRemote: "https://x/laravel-rls.git",
                           readmeHead: nil, claudeMdHead: nil, manifest: "acme/laravel-rls — RLS package")
  let p = ProjectContext.describePrompt(ctx)
  #expect(p.contains("Directory name: laravel-rls"))
  #expect(p.contains("Git remote: https://x/laravel-rls.git"))
  #expect(p.contains("acme/laravel-rls — RLS package"))
  #expect(!p.contains("README excerpt"))                 // nil signal omitted
  #expect(p.contains("Summarize what this software project"))   // description instruction, not naming
}

// MARK: hasMeaningfulSignal (substance gate)

@Test func meaningfulSignalTrueForSubstantiveReadme() {
  let ctx = ProjectContext(dirName: "app", gitRemote: nil,
                           readmeHead: "# App\nRow-level security for Eloquent models.",
                           claudeMdHead: nil, manifest: nil)
  #expect(ProjectContext.hasMeaningfulSignal(ctx) == true)
}

@Test func meaningfulSignalFalseForTitleOnlyReadme() {
  let ctx = ProjectContext(dirName: "foo", gitRemote: "https://x/foo.git",
                           readmeHead: "# foo", claudeMdHead: nil, manifest: nil)
  #expect(ProjectContext.hasMeaningfulSignal(ctx) == false)   // `# foo` alone is not enough
}

@Test func meaningfulSignalFalseForBareNameManifestAndRemoteOnly() {
  let ctx = ProjectContext(dirName: "foo", gitRemote: "https://x/foo.git",
                           readmeHead: nil, claudeMdHead: nil, manifest: "MyPackage")  // name only, no " — desc"
  #expect(ProjectContext.hasMeaningfulSignal(ctx) == false)
}

@Test func meaningfulSignalTrueForManifestWithDescription() {
  let ctx = ProjectContext(dirName: "foo", gitRemote: nil,
                           readmeHead: nil, claudeMdHead: nil, manifest: "acme/foo — does a real thing")
  #expect(ProjectContext.hasMeaningfulSignal(ctx) == true)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter ProjectContextTests`
Expected: FAIL — `describePrompt`/`hasMeaningfulSignal` are not members of `ProjectContext`.

- [ ] **Step 3: Implement `describePrompt`, `hasMeaningfulSignal`, and a shared `signalLines` helper**

In `Sources/PensieveKit/Ingest/ProjectContext.swift`, add these `static` members inside the `ProjectContext` struct (place them next to the existing `namePrompt`):

```swift
  /// The signal lines shared by `namePrompt` and `describePrompt` — present fields only.
  private static func signalLines(_ ctx: ProjectContext) -> [String] {
    var lines = ["Directory name: \(ctx.dirName)"]
    if let r = ctx.gitRemote { lines.append("Git remote: \(r)") }
    if let m = ctx.manifest { lines.append("Package manifest: \(m)") }
    if let rd = ctx.readmeHead { lines.append("README excerpt:\n\(rd)") }
    if let cm = ctx.claudeMdHead { lines.append("CLAUDE.md excerpt:\n\(cm)") }
    return lines
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
    if let m = ctx.manifest, m.contains(" — ") { return true }
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
```

Then DRY up the existing `namePrompt` to reuse `signalLines`. Replace its body's line-assembly block:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter ProjectContextTests`
Expected: PASS — all `ProjectContextTests` (existing `namePrompt`/`gather` tests still green after the `signalLines` refactor, plus the 5 new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Ingest/ProjectContext.swift Tests/PensieveKitTests/ProjectContextTests.swift
git commit -m "feat(kit): describePrompt + meaningful-signal gate on ProjectContext"
```

---

### Task 2: `NodeDescriber.Outcome` + `sanitize`

Create the `NodeDescriber` file with its typed outcome and the pure output sanitizer. No DB yet.

**Files:**
- Create: `Sources/PensieveKit/Intelligence/NodeDescriber.swift`
- Test: `Tests/PensieveKitTests/NodeDescriberTests.swift`

**Interfaces:**
- Produces:
  - `public enum NodeDescriber` (namespace)
  - `NodeDescriber.Outcome` — `enum Outcome: Equatable, Sendable { case wrote, attemptedEmpty, noSignal, ineligible }`
  - `static func sanitize(_ raw: String) -> String?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/NodeDescriberTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

// MARK: sanitize

@Test func sanitizeTrimsAndKeepsProse() {
  #expect(NodeDescriber.sanitize("  A tool for reconstructing project state.  ")
          == "A tool for reconstructing project state.")
}

@Test func sanitizeStripsLeadingListMarkerAndQuotes() {
  #expect(NodeDescriber.sanitize("- \"A native macOS capture tool.\"")
          == "A native macOS capture tool.")
}

@Test func sanitizeStripsCodeFences() {
  #expect(NodeDescriber.sanitize("```\nA background sync daemon.\n```")
          == "A background sync daemon.")
}

@Test func sanitizeStripsLeadingHeadingMarker() {
  #expect(NodeDescriber.sanitize("# A row-level-security package")
          == "A row-level-security package")
}

@Test func sanitizeReturnsNilForEmpty() {
  #expect(NodeDescriber.sanitize("   \n  ") == nil)
  #expect(NodeDescriber.sanitize("```\n\n```") == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter NodeDescriberTests`
Expected: FAIL — `NodeDescriber` is undefined.

- [ ] **Step 3: Implement `NodeDescriber` with `Outcome` and `sanitize`**

Create `Sources/PensieveKit/Intelligence/NodeDescriber.swift`:

```swift
import Foundation
import SQLiteData

/// Best-effort derivation of a git-backed project node's `description` ("what it is") from local
/// repo signals. Outside the strict cited trust gate — like strand naming and narration. The unit
/// is shared by the daemon pass (`Ingester.describeProjectNodes`) and the app's manual refresh.
public enum NodeDescriber {
  /// What a single `describe` call did. `.wrote` is terminal (the node now has a description);
  /// `.attemptedEmpty` and `.noSignal` leave the description empty (retried on a later pass);
  /// `.ineligible` = not a single-git-source project, or already-described without `force`.
  public enum Outcome: Equatable, Sendable { case wrote, attemptedEmpty, noSignal, ineligible }

  /// Normalizes a model's free-text description: trims; strips surrounding code fences; strips a
  /// leading list/heading marker; strips surrounding quotes. Returns nil when nothing is left.
  /// Brevity is left to the prompt (no sentence truncation — YAGNI, matching `narrate`).
  public static func sanitize(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("```") {
      s = s.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let marker = s.range(of: #"^(\d+[.)]|[-*•#]+)\s+"#, options: .regularExpression) {
      s.removeSubrange(marker)
    }
    s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter NodeDescriberTests`
Expected: PASS — 5 sanitize tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Intelligence/NodeDescriber.swift Tests/PensieveKitTests/NodeDescriberTests.swift
git commit -m "feat(kit): NodeDescriber.Outcome + output sanitizer"
```

---

### Task 3: `NodeDescriber.describe` (resolve → gather → LLM → write)

The IO entry point: resolve a node's single git source, gather signals, gate on substance, call the provider, write the sanitized description. Returns the typed `Outcome`.

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/NodeDescriber.swift`
- Test: `Tests/PensieveKitTests/NodeDescriberTests.swift` (append)

**Interfaces:**
- Consumes: `ProjectContext.gather`, `ProjectContext.hasMeaningfulSignal`, `ProjectContext.describePrompt` (Task 1); `NodeDescriber.Outcome`, `NodeDescriber.sanitize` (Task 2); `LLMProvider.complete`; `Node`, `Source`, `NodeKind.project`, `SourceKind.gitRepo`.
- Produces: `static func describe(_ db: any DatabaseWriter, nodeID: UUID, provider: any LLMProvider, force: Bool) async -> Outcome`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/NodeDescriberTests.swift`:

```swift
// MARK: describe (IO)

private struct StubLLM: LLMProvider {
  let text: String
  func complete(prompt: String) async throws -> String { text }
}

/// Records whether the provider was actually invoked (for the no-signal / no-LLM assertion).
private actor InvocationFlag { var invoked = false; func mark() { invoked = true } }
private struct SpyLLM: LLMProvider {
  let text: String
  let flag: InvocationFlag
  func complete(prompt: String) async throws -> String { await flag.mark(); return text }
}

/// Writes a file into a directory (creating intermediate dirs).
private func writeFile(_ text: String, to url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try text.write(to: url, atomically: true, encoding: .utf8)
}

/// A committed repo with a substantive README + a project node whose single git source points at it.
private func describableProjectNode(db: any DatabaseWriter) async throws -> (node: Node, repo: URL) {
  let (repo, _) = try makeCommittedRepo()
  try writeFile("# App\nRow-level security for Eloquent models, enforced at the database layer.",
                to: repo.appendingPathComponent("README.md"))
  let commonDir = Git.commonDir(in: repo.path)!
  let node = Node(name: "app", kind: NodeKind.project)
  try await db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { Source(nodeID: node.id, kind: SourceKind.gitRepo, key: commonDir) }.execute(db)
  }
  return (node, repo)
}

@Test func describeWritesDescriptionForSubstantiveRepo() async throws {
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(db: db)

  let outcome = await NodeDescriber.describe(db, nodeID: node.id,
                                             provider: StubLLM(text: "A row-level-security package for Laravel."),
                                             force: false)

  #expect(outcome == .wrote)
  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.description == "A row-level-security package for Laravel.")
}

@Test func describeReturnsNoSignalWithoutInvokingLLM() async throws {
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let (repo, _) = try makeCommittedRepo()   // no README/manifest → no meaningful signal
  let commonDir = Git.commonDir(in: repo.path)!
  let node = Node(name: "bare", kind: NodeKind.project)
  try await db.write { db in
    try Node.insert { node }.execute(db)
    try Source.insert { Source(nodeID: node.id, kind: SourceKind.gitRepo, key: commonDir) }.execute(db)
  }
  let flag = InvocationFlag()

  let outcome = await NodeDescriber.describe(db, nodeID: node.id,
                                             provider: SpyLLM(text: "should not run", flag: flag), force: false)

  #expect(outcome == .noSignal)
  #expect(await flag.invoked == false)       // gated before any LLM call
  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.description == "")
}

@Test func describeReturnsAttemptedEmptyWhenModelSaysNothing() async throws {
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(db: db)

  let outcome = await NodeDescriber.describe(db, nodeID: node.id,
                                             provider: StubLLM(text: "   "), force: false)

  #expect(outcome == .attemptedEmpty)
  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.description == "")           // nothing written → still eligible next pass
}

@Test func describeIsIneligibleForNonProjectNode() async throws {
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let node = Node(name: "s", kind: NodeKind.strand)
  try await db.write { db in try Node.insert { node }.execute(db) }

  let outcome = await NodeDescriber.describe(db, nodeID: node.id,
                                             provider: StubLLM(text: "x"), force: false)
  #expect(outcome == .ineligible)
}

@Test func describeIsIneligibleWithZeroOrTwoGitSources() async throws {
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  // Zero git sources.
  let a = Node(name: "a", kind: NodeKind.project)
  try await db.write { db in try Node.insert { a }.execute(db) }
  #expect(await NodeDescriber.describe(db, nodeID: a.id, provider: StubLLM(text: "x"), force: false) == .ineligible)
  // Two git sources (merged node).
  let b = Node(name: "b", kind: NodeKind.project)
  try await db.write { db in
    try Node.insert { b }.execute(db)
    try Source.insert { Source(nodeID: b.id, kind: SourceKind.gitRepo, key: "/x/.git") }.execute(db)
    try Source.insert { Source(nodeID: b.id, kind: SourceKind.gitRepo, key: "/y/.git") }.execute(db)
  }
  #expect(await NodeDescriber.describe(db, nodeID: b.id, provider: StubLLM(text: "x"), force: false) == .ineligible)
}

@Test func describeSkipsAlreadyDescribedUnlessForced() async throws {
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(db: db)
  try await db.write { db in
    try Node.where { $0.id.eq(node.id) }.update { $0.description = "Existing." }.execute(db)
  }

  // Without force: refuse to clobber.
  #expect(await NodeDescriber.describe(db, nodeID: node.id,
                                       provider: StubLLM(text: "New one."), force: false) == .ineligible)
  let mid = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(mid.description == "Existing.")

  // With force: overwrite.
  #expect(await NodeDescriber.describe(db, nodeID: node.id,
                                       provider: StubLLM(text: "New one."), force: true) == .wrote)
  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.description == "New one.")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter NodeDescriberTests`
Expected: FAIL — `describe` is not a member of `NodeDescriber`.

- [ ] **Step 3: Implement `describe`**

Add to `NodeDescriber` in `Sources/PensieveKit/Intelligence/NodeDescriber.swift`:

```swift
  /// Derive and write `nodeID`'s description. Eligible only for a `project` node with exactly one
  /// `gitRepo` source; `force` allows overwriting a non-empty description (the manual refresh) but
  /// never bypasses the single-git-source or meaningful-signal guards. Never throws — a provider
  /// failure or empty output is `.attemptedEmpty` (nothing written).
  public static func describe(_ db: any DatabaseWriter, nodeID: UUID,
                              provider: any LLMProvider, force: Bool) async -> Outcome {
    let resolved: (node: Node, key: String)? = (try? db.read { db -> (Node, String)? in
      guard let node = try Node.where({ $0.id.eq(nodeID) }).fetchOne(db),
            node.kind == NodeKind.project else { return nil }
      let git = try Source.where { $0.nodeID.eq(nodeID) && $0.kind.eq(SourceKind.gitRepo) }.fetchAll(db)
      guard git.count == 1, let key = git.first?.key else { return nil }
      return (node, key)
    }) ?? nil
    guard let resolved else { return .ineligible }
    if !force, !resolved.node.description.isEmpty { return .ineligible }

    let ctx = ProjectContext.gather(commonDir: resolved.key)
    guard ProjectContext.hasMeaningfulSignal(ctx) else { return .noSignal }

    guard let raw = try? await provider.complete(prompt: ProjectContext.describePrompt(ctx)),
          let desc = sanitize(raw) else { return .attemptedEmpty }

    try? db.write { db in
      try Node.where { $0.id.eq(nodeID) }.update { $0.description = desc }.execute(db)
    }
    return .wrote
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter NodeDescriberTests`
Expected: PASS — all sanitize + describe tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Intelligence/NodeDescriber.swift Tests/PensieveKitTests/NodeDescriberTests.swift
git commit -m "feat(kit): NodeDescriber.describe — resolve, gather, gate, write"
```

---

### Task 4: `Ingester.describeProjectNodes()` pass + `SyncRunner` wiring

The daemon pass: select eligible candidates, call `describe(force: false)`, and cap **actual LLM invocations** (not candidates) so signal-less repos never starve describable ones. Wire it into `SyncRunner.run()` next to `refineProjectNames()`.

**Files:**
- Modify: `Sources/PensieveKit/Ingest/Ingester.swift`
- Modify: `Sources/PensieveKit/Sync/SyncRunner.swift:41` (add one line after `refineProjectNames()`)
- Test: `Tests/PensieveKitTests/NodeDescriberTests.swift` (append pass-level tests)

**Interfaces:**
- Consumes: `NodeDescriber.describe` / `NodeDescriber.Outcome` (Task 3); Ingester's `db`, `llm`, `readSync`.
- Produces:
  - `Ingester.descriptionRefineCap: Int` (static, value 20)
  - `func describeProjectNodes() async` (internal, like `refineProjectNames`)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/NodeDescriberTests.swift`:

```swift
// MARK: describeProjectNodes (daemon pass)

@Test func passDescribesEligibleGitProjectNode() async throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(db: db)

  await Ingester(spool: spool, db: db, llm: StubLLM(text: "A capture-and-recall tool."))
    .describeProjectNodes()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.description == "A capture-and-recall tool.")
}

@Test func passIsNoOpWithoutProvider() async throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(db: db)

  await Ingester(spool: spool, db: db, llm: nil).describeProjectNodes()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.description == "")           // no provider → nothing attempted
}

@Test func passSkipsAlreadyDescribedNode() async throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  let db = try openCanonicalDatabase(at: tempURL("canon"))
  let (node, _) = try await describableProjectNode(db: db)
  try await db.write { db in
    try Node.where { $0.id.eq(node.id) }.update { $0.description = "Kept." }.execute(db)
  }

  await Ingester(spool: spool, db: db, llm: StubLLM(text: "Should not apply.")).describeProjectNodes()

  let after = try await db.read { db in try Node.where { $0.id.eq(node.id) }.fetchOne(db) }!
  #expect(after.description == "Kept.")      // non-empty description ⇒ not a candidate
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter NodeDescriberTests`
Expected: FAIL — `describeProjectNodes` is not a member of `Ingester`.

- [ ] **Step 3: Implement `describeProjectNodes` + `descriptionRefineCap`**

In `Sources/PensieveKit/Ingest/Ingester.swift`, add near `nameRefineCap` (around line 214):

```swift
  /// Per-pass cap on actual LLM description calls (a `.noSignal` candidate is free and does NOT
  /// consume a slot), so a batch of signal-less repos can't stall the sync cycle.
  static let descriptionRefineCap = 20
```

And add this method next to `refineProjectNames()`:

```swift
  /// Best-effort description pass for git project nodes. Selects `project` nodes with exactly one
  /// `gitRepo` source and an EMPTY description (the empty field is the retry condition — no marker),
  /// and fills them via `NodeDescriber`. The cap bounds real LLM calls, not candidates: a
  /// `.noSignal` result (thin/absent README) is free and leaves the node to retry once real content
  /// appears. No-op when no provider is configured (e.g. the app's LLM-less drain). Runs from
  /// `SyncRunner`, outside the trust gate — like `refineProjectNames`.
  func describeProjectNodes() async {
    guard let llm else { return }

    let candidates: [UUID] = (try? readSync { db -> [UUID] in
      let projects = try Node.where { $0.kind.eq(NodeKind.project) }.fetchAll(db)
      var out: [UUID] = []
      for node in projects where node.description.isEmpty {
        let git = try Source
          .where { $0.nodeID.eq(node.id) && $0.kind.eq(SourceKind.gitRepo) }.fetchAll(db)
        if git.count == 1 { out.append(node.id) }
      }
      return out
    }) ?? []

    Log.ingest.info("Describing project nodes: \(candidates.count, privacy: .public) candidates")
    var invocations = 0
    for id in candidates {
      if invocations >= Self.descriptionRefineCap { break }
      let outcome = await NodeDescriber.describe(db, nodeID: id, provider: llm, force: false)
      if outcome == .wrote || outcome == .attemptedEmpty { invocations += 1 }
    }
  }
```

- [ ] **Step 4: Wire the pass into `SyncRunner.run()`**

In `Sources/PensieveKit/Sync/SyncRunner.swift`, add one line immediately after the existing `await ingester.refineProjectNames()` (line 41):

```swift
    await ingester.refineProjectNames()
    await ingester.describeProjectNodes()
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter NodeDescriberTests`
Expected: PASS — the three pass-level tests green.

- [ ] **Step 6: Run the full suite to confirm no regressions**

Run: `./scripts/test.sh`
Expected: PASS — all existing tests plus the new ones (SyncRunner still compiles/behaves; nothing else touched).

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Ingest/Ingester.swift Sources/PensieveKit/Sync/SyncRunner.swift Tests/PensieveKitTests/NodeDescriberTests.swift
git commit -m "feat(kit): describeProjectNodes pass wired into SyncRunner"
```

---

### Task 5: App — retained provider, `describeNode`, `isDescribable`

Give `AppModel` a retained raw provider (currently only `SummaryBuilder` holds one, privately) and two methods the DetailView needs: the manual-refresh action and the button-visibility check.

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift` (provider field near line 140; `rebuildSummaryBuilder` near line 162; new methods near `narration`/`detail`)

**Interfaces:**
- Consumes: `NodeDescriber.describe` / `NodeDescriber.Outcome`; `makeDefaultLLMProvider`; `Source`, `SourceKind.gitRepo`, `NodeKind.project`.
- Produces (for Task 6):
  - `func describeNode(_ node: Node) async -> NodeDescriber.Outcome`
  - `func isDescribable(_ node: Node) -> Bool`

- [ ] **Step 1: Add a retained provider field**

In `Sources/PensieveApp/AppModel.swift`, just below the `summaryBuilder` declaration (line 140), add:

```swift
  /// The raw narration provider, retained so the manual "describe this node" action can call
  /// `NodeDescriber.describe` directly (SummaryBuilder's provider is private). Rebuilt alongside
  /// `summaryBuilder` on a provider/config change.
  private var descriptionProvider: any LLMProvider = ClaudeCLIProvider()
```

- [ ] **Step 2: Populate it in `rebuildSummaryBuilder`**

In `rebuildSummaryBuilder()` (line 162-164), capture the provider once and reuse it:

```swift
  func rebuildSummaryBuilder() {
    let (config, key) = cloudInputs()
    let provider = makeDefaultLLMProvider(cloudConfig: config, apiKey: key)
    summaryBuilder = SummaryBuilder(provider: provider)
    descriptionProvider = provider
    let kind = resolvedProviderKind(cloudConfig: config, apiKey: key)
```

(Leave the rest of the method — the `if kind == "cloud"` block and the log line — unchanged.)

- [ ] **Step 3: Add `isDescribable` and `describeNode`**

Add these methods to `AppModel` (place them right after the `narration(for:events:force:)` method, near line 544):

```swift
  /// True when `node` is a project with exactly one git source — i.e. `NodeDescriber` can act on
  /// it. Gates the DetailView's describe/refresh button so it never appears where it would no-op.
  func isDescribable(_ node: Node) -> Bool {
    guard node.kind == NodeKind.project, let db else { return false }
    let count = (try? db.read { db in
      try Source.where { $0.nodeID.eq(node.id) && $0.kind.eq(SourceKind.gitRepo) }.fetchAll(db).count
    }) ?? 0
    return count == 1
  }

  /// Manual "describe this node" action: force-derive `node`'s description off-main via the retained
  /// provider, then refresh so the new text renders. Best-effort — a failure/empty leaves the
  /// existing description untouched. Returns the outcome so the view can show an inline note.
  func describeNode(_ node: Node) async -> NodeDescriber.Outcome {
    guard let db else { return .ineligible }
    let outcome = await NodeDescriber.describe(db, nodeID: node.id, provider: descriptionProvider, force: true)
    refresh()
    return outcome
  }
```

- [ ] **Step 4: Build the app to verify it compiles**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift
git commit -m "feat(app): AppModel retained provider + describeNode/isDescribable"
```

---

### Task 6: App — DetailView button, progressive state, localization

Add the describe/refresh affordance to the "What It Is" section: a "Generate description" button when empty+describable, an `arrow.clockwise` button beside the text when described+describable, a spinner while running, and a "Nothing to summarize" inline note on an empty result. Localize the three new strings.

**Files:**
- Modify: `Sources/PensieveApp/DetailView.swift` (the "WHAT IT IS" block near lines 24-39; new `@State` near lines 14-19; the `.task` reset near lines 94-99)
- Modify: `Sources/PensieveApp/Localizable.xcstrings` (add three keys)

**Interfaces:**
- Consumes: `model.isDescribable(_:)`, `model.describeNode(_:)`, `NodeDescriber.Outcome` (Task 5).

- [ ] **Step 1: Add view state**

In `DetailView`, add alongside the existing `@State` declarations (after `loadedNodeID`, near line 18):

```swift
  @State private var isDescribing = false
  @State private var describeNote: String?   // brief inline note when a refresh yields nothing
```

- [ ] **Step 2: Reset the new state on node change / refresh**

In the `.task(id:)` closure, right after the existing `isNarrating = false` line (line 99), add:

```swift
      isNarrating = false
      isDescribing = false
      describeNote = nil
```

- [ ] **Step 3: Replace the description block with the affordance**

In the "WHAT IT IS" `VStack` (currently lines 35-37), replace:

```swift
            if !node.description.isEmpty {
              Text(node.description).prose().padding(.top, 2)
            }
```

with:

```swift
            descriptionBlock
```

Then add this computed property to `DetailView`, next to the `section(_:content:)` helper (near line 120):

```swift
  @ViewBuilder private var descriptionBlock: some View {
    let describable = model.isDescribable(node)
    VStack(alignment: .leading, spacing: 4) {
      if !node.description.isEmpty {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(node.description).prose()
          if describable {
            Button { runDescribe() } label: { Image(systemName: "arrow.clockwise") }
              .buttonStyle(.borderless).controlSize(.small)
              .help("Regenerate description")
              .disabled(isDescribing)
          }
        }
      } else if describable {
        Button { runDescribe() } label: {
          Label("Generate description", systemImage: "sparkles")
        }
        .buttonStyle(.borderless).controlSize(.small)
        .disabled(isDescribing)
      }
      if isDescribing, loadedNodeID == node.id {
        ProgressView().controlSize(.small)
      }
      if let describeNote, loadedNodeID == node.id {
        Text(describeNote).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.top, 2)
  }

  private func runDescribe() {
    describeNote = nil
    isDescribing = true
    Task {
      let outcome = await model.describeNode(node)
      guard loadedNodeID == node.id else { return }   // navigated away: drop the result
      isDescribing = false
      switch outcome {
      case .wrote: describeNote = nil
      case .noSignal, .attemptedEmpty: describeNote = String(localized: "Nothing to summarize")
      case .ineligible: describeNote = nil
      }
    }
  }
```

- [ ] **Step 4: Add the three localization keys**

In `Sources/PensieveApp/Localizable.xcstrings`, add three entries to the top-level `"strings"` object (mirroring the existing manual-key shape — English is the key itself; add a translated `de`). **Do not disturb existing entries or any concurrent uncommitted edits.**

```json
    "Generate description" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Beschreibung erstellen" } }
      }
    },
    "Regenerate description" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Beschreibung neu erstellen" } }
      }
    },
    "Nothing to summarize" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Nichts zusammenzufassen" } }
      }
    },
```

- [ ] **Step 5: Verify the catalog is valid JSON**

Run: `plutil -lint Sources/PensieveApp/Localizable.xcstrings`
Expected: `... OK`.

- [ ] **Step 6: Build + smoke-launch the app**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

Then a non-blocking smoke-launch against throwaway stores:
```bash
PENSIEVE_DB=$(mktemp -u).sqlite PENSIEVE_CAPTURE_DB=$(mktemp -u).sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 4; kill $PID 2>/dev/null; echo "launched+exited cleanly"
```
Expected: launches without crashing, prints `launched+exited cleanly`.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveApp/DetailView.swift Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): DetailView describe/refresh affordance + German l10n"
```

---

## Manual verification (human-run — needs the built app + a real store)

These need `open`ing the real `Pensieve.app` against the live store; they are the reviewer's/user's to run:

- A git project node with a README shows a generated description under its name; a strand keeps its activity description with **no** button; a Claude-only node shows no button.
- Clicking **Generate description** on an empty git node shows a spinner then prose; ⟳ on a described node re-derives.
- A git node with no README (or `# foo` only) shows the button; clicking it surfaces "Nothing to summarize" and leaves the text unchanged.
- Switching nodes mid-generation never renders one node's description under another.
- `-AppleLanguages '(de)'` launch shows the German button/label/note; the description **content** stays as generated (never translated).
- After a `pensieve sync` daemon cycle, previously-empty git project nodes gain descriptions; `pensieve list` names are unaffected.

## Post-merge carry

- The daemon change lives in PensieveKit → the release CLI (`~/.local/bin/pensieve`) and the launchd sync run must be rebuilt/reinstalled for the daemon `describeProjectNodes` pass to run in dogfooding.

---

## Self-Review

**Spec coverage:**
- `describePrompt` sibling over gathered signals → Task 1. ✓
- Substance-based meaningful-signal gate (thin `# foo` = no signal) → Task 1. ✓
- `NodeDescriber` shared unit, `Outcome`, sanitizer, no metadata marker → Tasks 2–3. ✓
- `describe` eligibility (project + exactly one git source), `force` overwrite semantics → Task 3. ✓
- `describeProjectNodes` pass, cap on **invocations** not candidates, empty-description candidacy → Task 4. ✓
- Correct call site `SyncRunner.run()` (not `drain()`, not `pensieve ingest`) → Task 4. ✓
- App retains raw provider; `describeNode`; button gated on exactly-one-git-source; "nothing to summarize" note; progressive/stale-guarded state → Tasks 5–6. ✓
- German l10n of the three new chrome strings; content never localized → Task 6. ✓
- Trust boundary untouched (best-effort, never in capture/ingest write path) → constraints + Task 4 wiring. ✓

**Placeholder scan:** No TBD/TODO; every code and test step is concrete.

**Type consistency:** `NodeDescriber.Outcome` (`.wrote`/`.attemptedEmpty`/`.noSignal`/`.ineligible`) is defined in Task 2 and used identically in Tasks 3–6. `describe(_:nodeID:provider:force:)`, `describeProjectNodes()`, `descriptionRefineCap`, `describeNode(_:)`, `isDescribable(_:)` signatures match across producer and consumer tasks. `ProjectContext.describePrompt`/`hasMeaningfulSignal` signatures consistent Task 1 → Task 3.
