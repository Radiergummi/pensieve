# Sync Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the live capture pipeline flow without manual steps — a launchd-scheduled `pensieve sync` drains the spool, discovers + ingests Claude session transcripts, and runs incremental loose-end extraction; a `SessionEnd` hook spools transcripts at true session end.

**Architecture:** Reuse the existing `Ingester.drain()` + `ExtractionRunner.run()` (now incremental). Add a pure, testable `TranscriptDiscovery` (glob → filter → paths to spool) and a pure `SyncRunner` (drain → discover+spool → drain → extract) in PensieveKit, wrapped by a thin `sync` CLI command. Add a dumb `capture-session-end` hook + its installer, and an `install-daemon` command that writes a launchd LaunchAgent plist (pure writer) and loads it (side effect).

**Tech Stack:** Swift 6, SQLiteData (GRDB-backed), ArgumentParser, PropertyListSerialization, launchctl (`gui/<uid>` domain). Tests use Swift Testing under `./scripts/test.sh`.

## Global Constraints

- **Build the CLI with `swift build`; run tests with `./scripts/test.sh`** (optionally `--filter <name>`), NEVER plain `swift test` (Command Line Tools only). On a SwiftSyntax/macro linker error, `rm -rf .build` and retry.
- **SQLiteData predicates use `.eq(x)`, NOT `== x`** (e.g. `.where { $0.fingerprint.eq(x) }`).
- Reuse `CaptureKind` / `SourceKind` constants (`CapturePayloads.swift`) — don't hardcode kind strings.
- **No shared mutable `static ISO8601DateFormatter`** (Swift 6 concurrency); use a local instance or `Date().ISO8601Format()` / `Date.ISO8601FormatStyle`.
- Tables are STRICT; PKs are UUID. The canonical store is single-writer (the ingester).
- **The capture path is sacred** — nothing here may block or break a git commit. `sync` only reads/ingests + writes the canonical store, small spool rows, its plist/log.
- **plist `PATH` must be absolute** (launchd does no `~` expansion) and include `/usr/bin` (`Git.run` execs `/usr/bin/env git`). Value: `<home>/.local/bin:/opt/homebrew/bin:/usr/bin:/bin`.
- **The daemon binary path is the stable `~/.local/bin/pensieve`**, never a `.build` path.
- No Python in shipped code. Swift only.
- Commit messages: use `git commit -F <file>` or single quotes (backticks in `-m "..."` get shell-executed). Keep trailers `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` and `Claude-Session: <url>`.

## File Structure

- `Sources/PensieveKit/Support/PensievePaths.swift` (modify) — add home/claude-projects/logs/launch-agent/installed-binary path helpers.
- `Sources/PensieveKit/Ingest/Ingester.swift` (modify) — permanent-drop for non-empty cwd-less session rows.
- `Sources/PensieveKit/Discovery/TranscriptDiscovery.swift` (create) — pure glob+filter.
- `Sources/PensieveKit/Capture/CapturePayloads.swift` (modify) — `sessionRefFromSessionEndHook(_:)` decoder helper.
- `Sources/pensieve/Commands/CaptureSessionEnd.swift` (create) — the dumb SessionEnd capture command.
- `Sources/PensieveKit/Capture/SettingsHookInstaller.swift` (modify) — generalize + add `installSessionEnd`.
- `Sources/pensieve/Commands/InstallSessionHook.swift` (modify) — install both hooks.
- `Sources/PensieveKit/Daemon/LaunchAgentPlist.swift` (create) — pure plist writer.
- `Sources/PensieveKit/Daemon/DaemonInstaller.swift` (create) — stable-path guard + launchctl load/unload.
- `Sources/pensieve/Commands/InstallDaemon.swift` (create) — `install-daemon [--uninstall]`.
- `Sources/PensieveKit/Query/SessionQueries.swift` (create) — `isIngested(db:sessionID:)`.
- `Sources/PensieveKit/Sync/SyncRunner.swift` (create) — the pure one-cycle runner.
- `Sources/pensieve/Commands/Sync.swift` (create) — the thin `sync` command.
- `Sources/pensieve/Pensieve.swift` (modify) — register `Sync`, `CaptureSessionEnd`, `InstallDaemon`.
- Tests under `Tests/PensieveKitTests/`: `PensievePathsTests`, `IngesterDropTests` (or extend existing), `TranscriptDiscoveryTests`, `SessionEndHookTests`, `SettingsHookInstallerSessionEndTests`, `LaunchAgentPlistTests`, `DaemonInstallerTests`, `SyncRunnerTests`.

---

### Task 1: PensievePaths helpers

**Files:**
- Modify: `Sources/PensieveKit/Support/PensievePaths.swift`
- Test: `Tests/PensieveKitTests/PensievePathsTests.swift`

**Interfaces:**
- Produces: `PensievePaths.homeDirectory() -> URL`, `.claudeProjectsURL() -> URL`, `.logsDirectory() -> URL`, `.syncLogURL() -> URL`, `.launchAgentURL() -> URL`, `.installedBinaryURL() -> URL`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/PensievePathsTests.swift`:

```swift
import Testing
import Foundation
@testable import PensieveKit

@Test func pathHelpersAreHomeRootedAndCorrectlySuffixed() {
  let home = PensievePaths.homeDirectory().path
  #expect(!home.isEmpty)
  #expect(PensievePaths.claudeProjectsURL().path == home + "/.claude/projects")
  #expect(PensievePaths.logsDirectory().path == home + "/Library/Logs/Pensieve")
  #expect(PensievePaths.syncLogURL().path == home + "/Library/Logs/Pensieve/sync.log")
  #expect(PensievePaths.launchAgentURL().path == home + "/Library/LaunchAgents/com.pensieve.sync.plist")
  #expect(PensievePaths.installedBinaryURL().path == home + "/.local/bin/pensieve")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter pathHelpersAreHomeRootedAndCorrectlySuffixed`
Expected: FAIL — `homeDirectory`/`claudeProjectsURL`/etc. are not members of `PensievePaths`.

- [ ] **Step 3: Add the helpers**

In `Sources/PensieveKit/Support/PensievePaths.swift`, add inside `enum PensievePaths` (after `captureURL()`):

```swift
  /// The current user's home, resolved via `getpwuid` (correct even when launchd does not
  /// export HOME) rather than the HOME environment variable.
  public static func homeDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
  }
  /// `~/.claude/projects` — where Claude Code writes session transcripts.
  public static func claudeProjectsURL() -> URL {
    homeDirectory().appendingPathComponent(".claude/projects", isDirectory: true)
  }
  /// `~/Library/Logs/Pensieve` — the daemon's log directory (launchd will not create it).
  public static func logsDirectory() -> URL {
    homeDirectory().appendingPathComponent("Library/Logs/Pensieve", isDirectory: true)
  }
  public static func syncLogURL() -> URL {
    logsDirectory().appendingPathComponent("sync.log")
  }
  /// `~/Library/LaunchAgents/com.pensieve.sync.plist`.
  public static func launchAgentURL() -> URL {
    homeDirectory().appendingPathComponent("Library/LaunchAgents/com.pensieve.sync.plist")
  }
  /// The stable installed CLI path baked into the daemon plist (never a `.build` path).
  public static func installedBinaryURL() -> URL {
    homeDirectory().appendingPathComponent(".local/bin/pensieve")
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter pathHelpersAreHomeRootedAndCorrectlySuffixed`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Support/PensievePaths.swift Tests/PensieveKitTests/PensievePathsTests.swift
git commit -F - <<'EOF'
feat: add daemon path helpers to PensievePaths

claudeProjectsURL / logsDirectory / syncLogURL / launchAgentURL /
installedBinaryURL, all rooted at homeDirectoryForCurrentUser (getpwuid,
HOME-independent under launchd).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

---

### Task 2: Ingester permanent-drop for non-empty cwd-less sessions

**Files:**
- Modify: `Sources/PensieveKit/Ingest/Ingester.swift` (the `CaptureKind.ccSession` branch of `ingest(_:)`, around the `guard let cwd` line)
- Test: `Tests/PensieveKitTests/IngesterDropTests.swift`

**Interfaces:**
- Consumes: existing `Ingester(spool:db:llm:)`, `CaptureSpool.append/pending/pendingCount`, `SessionRefPayload`, `CaptureKind.ccSession`.
- Produces: no new API — behavior change only. `drain()` now marks a non-empty-but-cwd-less `ccSession` row ingested (dropped) instead of leaving it pending forever; a 0-byte/unreadable transcript still stays pending.

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/IngesterDropTests.swift`:

```swift
import Testing
import Foundation
@testable import PensieveKit

private func tmp(_ name: String, ext: String) -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("\(name)-\(UUID().uuidString)").appendingPathExtension(ext)
}

@Test func drainDropsNonEmptyCwdlessSessionButRetriesEmpty() async throws {
  let spool = try CaptureSpool(at: tmp("drop-spool", ext: "sqlite"))
  let db = try openCanonicalDatabase(at: tmp("drop-canon", ext: "sqlite"))

  // (a) A non-empty transcript with NO cwd anywhere → permanently unattributable → drop.
  let noCwd = tmp("nocwd", ext: "jsonl")
  try #"{"type":"assistant","message":{"role":"assistant","content":"hi"}}"#
    .write(to: noCwd, atomically: true, encoding: .utf8)
  // (b) A 0-byte transcript → transient (may fill later) → stays pending.
  let empty = tmp("empty", ext: "jsonl")
  try "".write(to: empty, atomically: true, encoding: .utf8)

  for url in [noCwd, empty] {
    try spool.append(kind: CaptureKind.ccSession,
                     payload: try encodeJSON(SessionRefPayload(transcriptPath: url.path)))
  }

  let created = try await Ingester(spool: spool, db: db).drain()
  #expect(created == 0)                       // neither produced an event
  #expect(try spool.pendingCount() == 1)      // only the 0-byte row remains pending
  let remaining = try spool.pending()
  #expect(remaining.count == 1)
  #expect(remaining.first?.payload.contains("empty-") == true)   // the empty one stayed
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter drainDropsNonEmptyCwdlessSessionButRetriesEmpty`
Expected: FAIL — currently BOTH rows throw `unattributableSession` and stay pending, so `pendingCount == 2`.

- [ ] **Step 3: Change the guard**

In `Sources/PensieveKit/Ingest/Ingester.swift`, in the `case CaptureKind.ccSession:` branch, replace:

```swift
      // No cwd → transcript missing / not yet flushed. THROW so the row stays pending
      // and retries next drain, instead of being silently dropped.
      guard let cwd = session.cwd else { throw IngestError.unattributableSession }
```

with:

```swift
      // No cwd → can't attribute. Distinguish transient from permanent so discovery's
      // per-cycle re-spool can't loop forever: an empty/unreadable transcript may still fill
      // later (throw → stays pending, retries next drain); a non-empty transcript that still
      // has no cwd is corrupt/foreign and will never attribute (drop → drain marks it
      // ingested, returning 0 events).
      guard let cwd = session.cwd else {
        let size = (try? transcriptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size == 0 { throw IngestError.unattributableSession }
        return 0
      }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter drainDropsNonEmptyCwdlessSessionButRetriesEmpty`
Expected: PASS.

- [ ] **Step 5: Run the full suite (guard against regressions in existing ingest tests)**

Run: `./scripts/test.sh`
Expected: PASS (all existing tests + the new one).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Ingest/Ingester.swift Tests/PensieveKitTests/IngesterDropTests.swift
git commit -F - <<'EOF'
feat: drop permanently-unattributable session rows in drain

A non-empty ccSession transcript with no cwd is corrupt/foreign and will
never attribute; dropping it (return 0 -> drain marks it ingested) stops the
per-cycle discovery re-spool from looping forever. A 0-byte/unreadable
transcript may still fill later, so it keeps the retry (throw -> stays pending).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

---

### Task 3: TranscriptDiscovery (pure glob + filter)

**Files:**
- Create: `Sources/PensieveKit/Discovery/TranscriptDiscovery.swift`
- Test: `Tests/PensieveKitTests/TranscriptDiscoveryTests.swift`

**Interfaces:**
- Produces: `TranscriptDiscovery.discover(projectsDir: URL, now: Date, ageBound: TimeInterval = 7*24*60*60, alreadyIngested: (String) -> Bool) -> [URL]` — the transcript file URLs to spool this cycle.

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/TranscriptDiscoveryTests.swift`:

```swift
import Testing
import Foundation
@testable import PensieveKit

private func makeProjectsDir() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("proj-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root.appendingPathComponent("repoA"),
                                          withIntermediateDirectories: true)
  return root
}

/// Writes a transcript file under <projects>/repoA/<name>.jsonl with the given first-line JSON,
/// then stamps its modification date.
@discardableResult
private func writeTx(_ projects: URL, _ name: String, line: String, mtime: Date) throws -> URL {
  let url = projects.appendingPathComponent("repoA/\(name).jsonl")
  try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
  return url
}

@Test func discoverReturnsOnlyNewNonEmptyInWindowTopLevelTranscripts() throws {
  let projects = try makeProjectsDir()
  let now = Date(timeIntervalSince1970: 1_000_000)
  let cwdLine = #"{"type":"user","cwd":"/x","message":{"role":"user","content":"hi"}}"#

  // (a) already an event -> skipped without reading
  try writeTx(projects, "already", line: cwdLine, mtime: now)
  // (b) fresh, non-empty, in-window, has cwd -> RETURNED
  let wanted = try writeTx(projects, "wanted", line: cwdLine, mtime: now.addingTimeInterval(-60))
  // (c) ancient (older than 7d) -> skipped
  try writeTx(projects, "ancient", line: cwdLine, mtime: now.addingTimeInterval(-8 * 24 * 3600))
  // (d) 0-byte -> skipped
  let zero = projects.appendingPathComponent("repoA/zero.jsonl")
  try "".write(to: zero, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: zero.path)
  // (e) sidechain/subagent -> skipped
  try writeTx(projects, "sidechain",
              line: #"{"type":"user","cwd":"/x","isSidechain":true,"message":{"role":"user","content":"agent"}}"#,
              mtime: now)

  let result = TranscriptDiscovery.discover(projectsDir: projects, now: now) { sessionID in
    sessionID == "already"
  }
  #expect(result.map { $0.deletingPathExtension().lastPathComponent } == ["wanted"])
  #expect(result == [wanted])
}

@Test func discoverReturnsEmptyForMissingProjectsDir() {
  let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
  #expect(TranscriptDiscovery.discover(projectsDir: missing, now: Date()) { _ in false }.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter discoverReturns`
Expected: FAIL — `TranscriptDiscovery` does not exist.

- [ ] **Step 3: Implement TranscriptDiscovery**

Create `Sources/PensieveKit/Discovery/TranscriptDiscovery.swift`:

```swift
import Foundation

/// Pure discovery of Claude Code session transcripts to ingest this cycle. No DB access — the
/// caller injects `alreadyIngested`. Filters (cheapest first): already-an-event (no file read),
/// 0-byte, out-of-window (mtime), and subagent/sidechain transcripts.
public enum TranscriptDiscovery {
  public static func discover(projectsDir: URL, now: Date,
                              ageBound: TimeInterval = 7 * 24 * 60 * 60,
                              alreadyIngested: (String) -> Bool) -> [URL] {
    let fm = FileManager.default
    guard let projectDirs = try? fm.contentsOfDirectory(
      at: projectsDir, includingPropertiesForKeys: nil) else { return [] }

    var out: [URL] = []
    for dir in projectDirs {
      guard let files = try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
      for file in files where file.pathExtension == "jsonl" {
        let sessionID = file.deletingPathExtension().lastPathComponent
        if alreadyIngested(sessionID) { continue }                       // cost guard: no read
        let vals = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if (vals?.fileSize ?? 0) == 0 { continue }                       // not yet populated
        if let mtime = vals?.contentModificationDate,
           now.timeIntervalSince(mtime) > ageBound { continue }          // too old to re-glob
        if isSidechainTranscript(file) { continue }                      // subagent -> precision gate
        out.append(file)
      }
    }
    return out
  }

  /// True if any record in the transcript is flagged `isSidechain: true` (a Claude Code
  /// subagent/Task transcript). Defensive/future-proofing: current Claude Code stores subagent
  /// transcripts outside `~/.claude/projects`, so this matches 0 real files today — but it keeps
  /// agent-internal prose out of the loose-end extractor (the make-or-break precision gate) if
  /// that changes. Only reads files that survived the cheaper filters (i.e. new sessions), so a
  /// given transcript is read at most until it becomes an event.
  static func isSidechainTranscript(_ url: URL) -> Bool {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      if (obj["isSidechain"] as? Bool) == true { return true }
    }
    return false
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter discoverReturns`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Discovery/TranscriptDiscovery.swift Tests/PensieveKitTests/TranscriptDiscoveryTests.swift
git commit -F - <<'EOF'
feat: TranscriptDiscovery — pure glob+filter of session transcripts

Filters cheapest-first: already-an-event (no read), 0-byte, out-of-7d-window
(mtime), and isSidechain/subagent transcripts (defensive; 0 real files today).
No grace window — incremental re-extraction makes mid-write ingest safe.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

---

### Task 4: `sessionRefFromSessionEndHook` decoder + `capture-session-end` command

**Files:**
- Modify: `Sources/PensieveKit/Capture/CapturePayloads.swift`
- Create: `Sources/pensieve/Commands/CaptureSessionEnd.swift`
- Modify: `Sources/pensieve/Pensieve.swift` (register `CaptureSessionEnd`)
- Test: `Tests/PensieveKitTests/SessionEndHookTests.swift`

**Interfaces:**
- Produces: `sessionRefFromSessionEndHook(_ data: Data) -> SessionRefPayload?` (nil for malformed JSON or empty/absent `transcript_path`); a `capture-session-end` CLI subcommand.
- Consumes: `CaptureSpool.append`, `CaptureKind.ccSession`, `SessionRefPayload`, `encodeJSON`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/SessionEndHookTests.swift`:

```swift
import Testing
import Foundation
@testable import PensieveKit

@Test func sessionEndHookDecodesTranscriptPathAndRejectsGarbage() throws {
  let good = #"{"session_id":"s1","cwd":"/x","transcript_path":"/tmp/t.jsonl","reason":"clear"}"#
  #expect(sessionRefFromSessionEndHook(Data(good.utf8))?.transcriptPath == "/tmp/t.jsonl")

  #expect(sessionRefFromSessionEndHook(Data("not json".utf8)) == nil)
  #expect(sessionRefFromSessionEndHook(Data(#"{"reason":"other"}"#.utf8)) == nil)   // no path
  #expect(sessionRefFromSessionEndHook(Data(#"{"transcript_path":""}"#.utf8)) == nil) // empty
}

@Test func sessionEndHookSpoolsExactlyOneSessionRow() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("se-spool-\(UUID().uuidString).sqlite")
  let spool = try CaptureSpool(at: url)
  let ref = sessionRefFromSessionEndHook(Data(#"{"transcript_path":"/tmp/x.jsonl"}"#.utf8))!
  try spool.append(kind: CaptureKind.ccSession, payload: try encodeJSON(ref))
  let rows = try spool.pending()
  #expect(rows.count == 1)
  #expect(rows.first?.kind == CaptureKind.ccSession)
  #expect(rows.first?.payload.contains("/tmp/x.jsonl") == true)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter sessionEndHook`
Expected: FAIL — `sessionRefFromSessionEndHook` does not exist.

- [ ] **Step 3: Add the decoder helper**

In `Sources/PensieveKit/Capture/CapturePayloads.swift`, add at the end (after `encodeJSON`):

```swift
/// Decodes a Claude Code `SessionEnd` hook payload (stdin JSON) into a spoolable session ref.
/// Returns nil for malformed JSON or an empty/absent `transcript_path` — dumb by design: the
/// hook must never fail a session.
public func sessionRefFromSessionEndHook(_ data: Data) -> SessionRefPayload? {
  struct HookInput: Decodable { let transcript_path: String? }
  guard let h = try? JSONDecoder().decode(HookInput.self, from: data),
        let path = h.transcript_path, !path.isEmpty else { return nil }
  return SessionRefPayload(transcriptPath: path)
}
```

- [ ] **Step 4: Create the command**

Create `Sources/pensieve/Commands/CaptureSessionEnd.swift`:

```swift
import ArgumentParser
import Foundation
import PensieveKit

struct CaptureSessionEnd: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "capture-session-end",
    abstract: "Record a Claude Code transcript at session end (reads hook JSON from stdin).")

  func run() throws {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let ref = sessionRefFromSessionEndHook(data) else { return }  // dumb: never fail a session
    try? openSpool().append(kind: CaptureKind.ccSession, payload: try encodeJSON(ref))
  }
}
```

- [ ] **Step 5: Register the command**

In `Sources/pensieve/Pensieve.swift`, add `CaptureSessionEnd.self,` to the `subcommands:` array (next to `CaptureSessionStart.self`).

- [ ] **Step 6: Build + run tests**

Run: `swift build` then `./scripts/test.sh --filter sessionEndHook`
Expected: `swift build` succeeds; both tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Capture/CapturePayloads.swift Sources/pensieve/Commands/CaptureSessionEnd.swift Sources/pensieve/Pensieve.swift Tests/PensieveKitTests/SessionEndHookTests.swift
git commit -F - <<'EOF'
feat: capture-session-end hook + sessionRefFromSessionEndHook decoder

Dumb, fire-and-forget SessionEnd capture: reads hook JSON from stdin, spools a
SessionRefPayload (cc.session) for the transcript_path. Nil-safe for garbage/
empty input — never fails a session. Registered as a subcommand.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

---

### Task 5: SettingsHookInstaller — install the SessionEnd hook

**Files:**
- Modify: `Sources/PensieveKit/Capture/SettingsHookInstaller.swift`
- Modify: `Sources/pensieve/Commands/InstallSessionHook.swift`
- Test: `Tests/PensieveKitTests/SettingsHookInstallerSessionEndTests.swift`

**Interfaces:**
- Produces: `SettingsHookInstaller.installSessionEnd(settingsURL: URL, pensievePath: String) throws -> Bool`. Existing `install(settingsURL:pensievePath:) -> Bool` (SessionStart) keeps its signature/behavior.

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/SettingsHookInstallerSessionEndTests.swift`:

```swift
import Testing
import Foundation
@testable import PensieveKit

private func tmpSettings() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("settings-\(UUID().uuidString).json")
}

@Test func installsSessionEndWithEmptyMatcherIdempotentlyPreservingOthers() throws {
  let url = tmpSettings()
  // Pre-existing SessionStart (ours) + a foreign hook must survive.
  try SettingsHookInstaller.install(settingsURL: url, pensievePath: "/bin/pensieve")
  let seeded = try Data(contentsOf: url)
  var root = try JSONSerialization.jsonObject(with: seeded) as! [String: Any]
  var hooks = root["hooks"] as! [String: Any]
  hooks["Stop"] = [["matcher": "x", "hooks": [["type": "command", "command": "/other tool"]]]]
  root["hooks"] = hooks
  try JSONSerialization.data(withJSONObject: root).write(to: url)

  let first = try SettingsHookInstaller.installSessionEnd(settingsURL: url, pensievePath: "/bin/pensieve")
  let second = try SettingsHookInstaller.installSessionEnd(settingsURL: url, pensievePath: "/bin/pensieve")
  #expect(first == true)     // added
  #expect(second == false)   // idempotent

  let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  let h = obj["hooks"] as! [String: Any]
  let sessionEnd = h["SessionEnd"] as! [[String: Any]]
  #expect(sessionEnd.count == 1)
  #expect(sessionEnd[0]["matcher"] as? String == "")
  let cmd = ((sessionEnd[0]["hooks"] as! [[String: Any]])[0]["command"] as! String)
  #expect(cmd.contains("capture-session-end"))
  #expect(h["SessionStart"] != nil)   // preserved
  #expect(h["Stop"] != nil)           // foreign preserved
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter installsSessionEnd`
Expected: FAIL — `installSessionEnd` does not exist.

- [ ] **Step 3: Refactor + add installSessionEnd**

Replace the body of `enum SettingsHookInstaller` in `Sources/PensieveKit/Capture/SettingsHookInstaller.swift` with:

```swift
public enum SettingsHookInstaller {
  static let command = "capture-session-start"
  static let sessionEndCommand = "capture-session-end"

  /// Installs the `SessionStart` hook. Returns true if added, false if already present.
  @discardableResult
  public static func install(settingsURL: URL, pensievePath: String) throws -> Bool {
    try installHook(settingsURL: settingsURL, event: "SessionStart", matcher: "startup",
                    marker: command, command: "\(pensievePath) \(command)")
  }

  /// Installs the `SessionEnd` hook (matcher "" = all reasons). Returns true if added.
  @discardableResult
  public static func installSessionEnd(settingsURL: URL, pensievePath: String) throws -> Bool {
    try installHook(settingsURL: settingsURL, event: "SessionEnd", matcher: "",
                    marker: sessionEndCommand, command: "\(pensievePath) \(sessionEndCommand)")
  }

  /// Idempotent JSON merge of one Claude Code command hook into a settings.json. Preserves all
  /// existing content and never modifies foreign hook entries. Presence is detected by the
  /// subcommand `marker` substring (so a changed `pensievePath` is still recognized as ours).
  private static func installHook(settingsURL: URL, event: String, matcher: String,
                                  marker: String, command: String) throws -> Bool {
    var root: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: settingsURL.path) {
      guard let data = try? Data(contentsOf: settingsURL),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SettingsHookInstallError.unparseableSettings(settingsURL)
      }
      root = obj
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    var group = hooks[event] as? [[String: Any]] ?? []

    let present = group.contains { g in
      ((g["hooks"] as? [[String: Any]]) ?? []).contains {
        ($0["command"] as? String)?.contains(marker) == true
      }
    }
    if present { return false }

    group.append([
      "matcher": matcher,
      "hooks": [["type": "command", "command": command]],
    ])
    hooks[event] = group
    root["hooks"] = hooks

    try PensievePaths.ensureParentDirectory(of: settingsURL)
    let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try out.write(to: settingsURL, options: .atomic)
    return true
  }
}
```

Note: `SettingsHookInstallError` (above this enum in the same file) is unchanged — keep it.

- [ ] **Step 4: Wire the command to install both hooks**

In `Sources/pensieve/Commands/InstallSessionHook.swift`, update the `run()` body:

```swift
  func run() throws {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    let pensievePath = Bundle.main.executablePath ?? "pensieve"
    let start = try SettingsHookInstaller.install(settingsURL: url, pensievePath: pensievePath)
    let end = try SettingsHookInstaller.installSessionEnd(settingsURL: url, pensievePath: pensievePath)
    print(start ? "installed SessionStart hook in \(url.path)" : "SessionStart hook already present in \(url.path)")
    print(end ? "installed SessionEnd hook in \(url.path)" : "SessionEnd hook already present in \(url.path)")
  }
```

- [ ] **Step 5: Run tests (new + existing installer test must both pass)**

Run: `./scripts/test.sh --filter HookInstaller`
Expected: PASS — the new `installsSessionEnd…` test and any existing `SettingsHookInstaller` / SessionStart tests (behavior for SessionStart is unchanged).

- [ ] **Step 6: Full suite**

Run: `./scripts/test.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Capture/SettingsHookInstaller.swift Sources/pensieve/Commands/InstallSessionHook.swift Tests/PensieveKitTests/SettingsHookInstallerSessionEndTests.swift
git commit -F - <<'EOF'
feat: install the SessionEnd hook (matcher "") into settings.json

Generalize SettingsHookInstaller into a private installHook helper; add
installSessionEnd. install-session-hook now installs both SessionStart and
SessionEnd. Idempotent, foreign-hook-preserving; presence keyed on the
subcommand marker so a changed binary path is still recognized.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

---

### Task 6: LaunchAgentPlist (pure plist writer)

**Files:**
- Create: `Sources/PensieveKit/Daemon/LaunchAgentPlist.swift`
- Test: `Tests/PensieveKitTests/LaunchAgentPlistTests.swift`

**Interfaces:**
- Produces: `LaunchAgentPlist.label: String`; `LaunchAgentPlist.dictionary(pensievePath: String, home: URL, interval: Int = 300) -> [String: Any]`; `LaunchAgentPlist.data(pensievePath: String, home: URL, interval: Int = 300) throws -> Data` (XML plist).

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/LaunchAgentPlistTests.swift`:

```swift
import Testing
import Foundation
@testable import PensieveKit

@Test func plistHasStablePathAbsolutePATHAndBackgroundType() throws {
  let home = URL(fileURLWithPath: "/Users/tester")
  let d = LaunchAgentPlist.dictionary(pensievePath: "/Users/tester/.local/bin/pensieve", home: home)

  #expect(d["Label"] as? String == "com.pensieve.sync")
  #expect(d["ProgramArguments"] as? [String] == ["/Users/tester/.local/bin/pensieve", "sync"])
  #expect(d["StartInterval"] as? Int == 300)
  #expect(d["RunAtLoad"] as? Bool == true)
  #expect(d["ProcessType"] as? String == "Background")
  #expect(d["StandardOutPath"] as? String == "/Users/tester/Library/Logs/Pensieve/sync.log")

  let path = (d["EnvironmentVariables"] as? [String: String])?["PATH"] ?? ""
  #expect(!path.contains("~"))                                   // launchd does not expand ~
  #expect(path.contains("/usr/bin"))                             // Git.run needs /usr/bin/env git
  #expect(path.contains("/Users/tester/.local/bin"))            // claude -p fallback
  #expect(path.contains("/opt/homebrew/bin"))
}

@Test func plistDataRoundTripsAsXML() throws {
  let home = URL(fileURLWithPath: "/Users/tester")
  let data = try LaunchAgentPlist.data(pensievePath: "/Users/tester/.local/bin/pensieve", home: home)
  let obj = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
  #expect(obj["Label"] as? String == "com.pensieve.sync")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter plist`
Expected: FAIL — `LaunchAgentPlist` does not exist.

- [ ] **Step 3: Implement LaunchAgentPlist**

Create `Sources/PensieveKit/Daemon/LaunchAgentPlist.swift`:

```swift
import Foundation

/// Pure writer for the `com.pensieve.sync` LaunchAgent plist. All paths are ABSOLUTE — launchd
/// performs no `~`/shell expansion of plist values.
public enum LaunchAgentPlist {
  public static let label = "com.pensieve.sync"

  public static func dictionary(pensievePath: String, home: URL, interval: Int = 300) -> [String: Any] {
    let logPath = home.appendingPathComponent("Library/Logs/Pensieve/sync.log").path
    // launchd REPLACES the job PATH (no login-PATH inheritance): /usr/bin+/bin are mandatory for
    // Git.run's `/usr/bin/env git`; ~/.local/bin (expanded) + /opt/homebrew/bin resolve `claude`
    // for the extraction fallback.
    let path = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
    return [
      "Label": label,
      "ProgramArguments": [pensievePath, "sync"],
      "StartInterval": interval,
      "RunAtLoad": true,
      "ProcessType": "Background",
      "StandardOutPath": logPath,
      "StandardErrorPath": logPath,
      "EnvironmentVariables": ["PATH": path],
    ]
  }

  public static func data(pensievePath: String, home: URL, interval: Int = 300) throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: dictionary(pensievePath: pensievePath, home: home, interval: interval),
      format: .xml, options: 0)
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter plist`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Daemon/LaunchAgentPlist.swift Tests/PensieveKitTests/LaunchAgentPlistTests.swift
git commit -F - <<'EOF'
feat: LaunchAgentPlist — pure com.pensieve.sync plist writer

Absolute paths only (launchd doesn't expand ~). PATH includes /usr/bin (for
Git.run) + <home>/.local/bin + /opt/homebrew/bin (for the claude -p fallback).
ProcessType=Background, StartInterval=300, RunAtLoad, sync.log out/err.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

---

### Task 7: DaemonInstaller + `install-daemon` command

**Files:**
- Create: `Sources/PensieveKit/Daemon/DaemonInstaller.swift`
- Create: `Sources/pensieve/Commands/InstallDaemon.swift`
- Modify: `Sources/pensieve/Pensieve.swift` (register `InstallDaemon`)
- Test: `Tests/PensieveKitTests/DaemonInstallerTests.swift`

**Interfaces:**
- Produces: `DaemonInstaller.stablePensievePath(home: URL) -> String`; `DaemonInstaller.ensureStable(runningExecutable: String) throws`; `DaemonInstaller.writePlist(home: URL, runningExecutable: String, plistURL: URL) throws` (pure-ish: guard + create log dir + write plist; no launchctl); `DaemonInstaller.load(plistURL: URL, uid: String)` / `.unload(plistURL: URL, uid: String)` (launchctl side effects); `DaemonInstallError`.
- Consumes: `LaunchAgentPlist`, `PensievePaths`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/DaemonInstallerTests.swift`:

```swift
import Testing
import Foundation
@testable import PensieveKit

@Test func stablePathIsLocalBinAndBuildPathsAreRefused() throws {
  let home = URL(fileURLWithPath: "/Users/tester")
  #expect(DaemonInstaller.stablePensievePath(home: home) == "/Users/tester/.local/bin/pensieve")

  // A .build path must be refused.
  var threw = false
  do { try DaemonInstaller.ensureStable(runningExecutable: "/repo/.build/debug/pensieve") }
  catch { threw = true }
  #expect(threw)

  // A normal installed path is accepted.
  try DaemonInstaller.ensureStable(runningExecutable: "/Users/tester/.local/bin/pensieve")
}

@Test func writePlistCreatesLogDirAndStablePlist() throws {
  let home = FileManager.default.temporaryDirectory
    .appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
  let plistURL = home.appendingPathComponent("Library/LaunchAgents/com.pensieve.sync.plist")
  try DaemonInstaller.writePlist(home: home, runningExecutable: home.appendingPathComponent(".local/bin/pensieve").path, plistURL: plistURL)

  #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Logs/Pensieve").path))
  let obj = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
  #expect((obj["ProgramArguments"] as? [String])?.first == home.appendingPathComponent(".local/bin/pensieve").path)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter Daemon`
Expected: FAIL — `DaemonInstaller` does not exist.

- [ ] **Step 3: Implement DaemonInstaller**

Create `Sources/PensieveKit/Daemon/DaemonInstaller.swift`:

```swift
import Foundation

public enum DaemonInstallError: Error, CustomStringConvertible {
  case runningFromBuild(String)
  public var description: String {
    switch self {
    case .runningFromBuild(let p):
      return "Refusing to install the daemon from a .build path (\(p)). Install the release binary to ~/.local/bin/pensieve and run install-daemon from there."
    }
  }
}

/// Installs/uninstalls the `com.pensieve.sync` LaunchAgent. The plist-writing half is pure and
/// tested; the `launchctl` half is a side effect (smoke-verified by hand).
public enum DaemonInstaller {
  /// The stable path baked into the plist — NOT `Bundle.main.executablePath` (which resolves into
  /// `.build/…` under `swift run`; a routine `rm -rf .build` would then silently kill the daemon).
  public static func stablePensievePath(home: URL) -> String {
    home.appendingPathComponent(".local/bin/pensieve").path
  }

  /// Refuse to install when the running binary is under `.build`.
  public static func ensureStable(runningExecutable: String) throws {
    if runningExecutable.contains("/.build/") {
      throw DaemonInstallError.runningFromBuild(runningExecutable)
    }
  }

  /// Guard + create the log dir + write the plist. No `launchctl`. `home` roots all paths.
  public static func writePlist(home: URL, runningExecutable: String, plistURL: URL) throws {
    try ensureStable(runningExecutable: runningExecutable)
    let logsDir = home.appendingPathComponent("Library/Logs/Pensieve", isDirectory: true)
    try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    try PensievePaths.ensureParentDirectory(of: plistURL)
    let data = try LaunchAgentPlist.data(pensievePath: stablePensievePath(home: home), home: home)
    try data.write(to: plistURL, options: .atomic)
  }

  /// Reload-always: bootout (ignore "not loaded") then bootstrap (retry the teardown race).
  public static func load(plistURL: URL, uid: String) {
    _ = launchctl(["bootout", "gui/\(uid)", plistURL.path])
    for _ in 0..<3 {
      if launchctl(["bootstrap", "gui/\(uid)", plistURL.path]) == 0 { return }
      Thread.sleep(forTimeInterval: 0.3)   // bootout returns before teardown completes
    }
  }

  public static func unload(plistURL: URL, uid: String) {
    _ = launchctl(["bootout", "gui/\(uid)", plistURL.path])
    try? FileManager.default.removeItem(at: plistURL)
  }

  @discardableResult
  private static func launchctl(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
  }
}
```

- [ ] **Step 4: Create the command**

Create `Sources/pensieve/Commands/InstallDaemon.swift`:

```swift
import ArgumentParser
import Foundation
import PensieveKit

struct InstallDaemon: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "install-daemon",
    abstract: "Install (or --uninstall) the launchd agent that runs `pensieve sync` every 5 min.")

  @Flag(name: .long, help: "Remove the daemon instead of installing it.")
  var uninstall = false

  func run() throws {
    let home = PensievePaths.homeDirectory()
    let plistURL = PensievePaths.launchAgentURL()
    let uid = String(getuid())

    if uninstall {
      DaemonInstaller.unload(plistURL: plistURL, uid: uid)
      print("uninstalled daemon (\(plistURL.path))")
      return
    }

    let running = Bundle.main.executablePath ?? ""
    try DaemonInstaller.writePlist(home: home, runningExecutable: running, plistURL: plistURL)
    DaemonInstaller.load(plistURL: plistURL, uid: uid)
    print("installed daemon: runs `\(DaemonInstaller.stablePensievePath(home: home)) sync` every 5 min")
  }
}
```

- [ ] **Step 5: Register the command**

In `Sources/pensieve/Pensieve.swift`, add `InstallDaemon.self,` to the `subcommands:` array.

- [ ] **Step 6: Build + run tests**

Run: `swift build` then `./scripts/test.sh --filter Daemon`
Expected: `swift build` succeeds; both tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveKit/Daemon/DaemonInstaller.swift Sources/pensieve/Commands/InstallDaemon.swift Sources/pensieve/Pensieve.swift Tests/PensieveKitTests/DaemonInstallerTests.swift
git commit -F - <<'EOF'
feat: install-daemon — write + load the com.pensieve.sync LaunchAgent

Refuses a .build binary path (routine rm -rf .build would kill the daemon);
bakes the stable ~/.local/bin/pensieve path; creates the log dir; reload-always
bootout->bootstrap with teardown-race retry. --uninstall boots out + removes the
plist. Pure writePlist tested; launchctl smoke-verified by hand.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

---

### Task 8: SessionQueries + SyncRunner + `sync` command

**Files:**
- Create: `Sources/PensieveKit/Query/SessionQueries.swift`
- Create: `Sources/PensieveKit/Sync/SyncRunner.swift`
- Create: `Sources/pensieve/Commands/Sync.swift`
- Modify: `Sources/pensieve/Pensieve.swift` (register `Sync`)
- Test: `Tests/PensieveKitTests/SyncRunnerTests.swift`

**Interfaces:**
- Consumes: `Ingester`, `ExtractionRunner`, `TranscriptDiscovery`, `CaptureSpool`, `SessionRefPayload`, `CaptureKind`, `Fingerprint`, `Event`, `PensievePaths`, `makeDefaultLLMProvider()`.
- Produces: `SessionQueries.isIngested(_ db: any DatabaseReader, sessionID: String) throws -> Bool`; `SyncRunner(spool:db:provider:projectsDir:now:)` with `.run() async throws -> SyncRunner.Summary` (`ingested`, `discovered`, `extracted`); a `sync` CLI subcommand.

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/SyncRunnerTests.swift`:

```swift
import Testing
import Foundation
@testable import PensieveKit

private func tmp(_ n: String, ext: String) -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("\(n)-\(UUID().uuidString)").appendingPathExtension(ext)
}

/// A provider that returns no loose ends — keeps SyncRunner tests about discovery/ingestion,
/// not extraction content (extraction correctness is covered by ExtractionRunnerTests). All
/// three methods are implemented explicitly so extraction never throws (the default
/// classifyGenuineIndices throws on an unparseable response), keeping the watermark assertion
/// deterministic.
private struct NoopProvider: LLMProvider {
  func complete(prompt: String) async throws -> String { "" }
  func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] { [] }
  func classifyGenuineIndices(prompt: String) async throws -> [Int] { [] }
}

/// Writes a minimal but attributable transcript (has cwd + a user prompt) under
/// <projects>/repoA/<sessionID>.jsonl.
@discardableResult
private func writeSession(_ projects: URL, _ sessionID: String, prompts: Int) throws -> URL {
  let dir = projects.appendingPathComponent("repoA", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let cwd = FileManager.default.temporaryDirectory.path
  var lines: [String] = []
  for i in 0..<prompts {
    lines.append(#"{"type":"user","cwd":"\#(cwd)","timestamp":"2026-06-30T10:0\#(i):00Z","message":{"role":"user","content":"prompt \#(i)"}}"#)
  }
  let url = dir.appendingPathComponent("\(sessionID).jsonl")
  try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  return url
}

@Test func syncDiscoversIngestsThenNoOpsThenReextractsOnGrowth() async throws {
  let projects = tmp("projects", ext: "d")
  try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
  let sessionID = UUID().uuidString
  let txURL = try writeSession(projects, sessionID, prompts: 1)

  let spool = try CaptureSpool(at: tmp("sync-spool", ext: "sqlite"))
  let db = try openCanonicalDatabase(at: tmp("sync-canon", ext: "sqlite"))
  func runner() -> SyncRunner {
    SyncRunner(spool: spool, db: db, provider: NoopProvider(),
               projectsDir: projects, now: { Date() })
  }

  // Cycle 1: discovers + ingests the session.
  let s1 = try await runner().run()
  #expect(s1.discovered == 1)
  #expect(s1.ingested >= 1)
  let ingested = try await db.read { db in
    try Event.where { $0.fingerprint.eq(Fingerprint.session(sessionID: sessionID)) }.fetchOne(db)
  }
  #expect(ingested != nil)
  let sizeAfter1 = ingested?.extractedTranscriptSize ?? -99

  // Cycle 2: nothing new — already an event, byte size unchanged.
  let s2 = try await runner().run()
  #expect(s2.discovered == 0)
  #expect(s2.ingested == 0)

  // Grow the transcript, then Cycle 3 re-extracts (watermark size advances).
  let more = #"{"type":"user","cwd":"\#(FileManager.default.temporaryDirectory.path)","timestamp":"2026-06-30T10:05:00Z","message":{"role":"user","content":"prompt later"}}"# + "\n"
  let handle = try FileHandle(forWritingTo: txURL)
  try handle.seekToEnd(); handle.write(Data(more.utf8)); try handle.close()

  _ = try await runner().run()
  let after3 = try await db.read { db in
    try Event.where { $0.fingerprint.eq(Fingerprint.session(sessionID: sessionID)) }.fetchOne(db)
  }
  #expect((after3?.extractedTranscriptSize ?? -1) > sizeAfter1)   // re-extraction ran on growth
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter syncDiscoversIngests`
Expected: FAIL — `SessionQueries` / `SyncRunner` do not exist.

- [ ] **Step 3: Implement SessionQueries**

Create `Sources/PensieveKit/Query/SessionQueries.swift`:

```swift
import Foundation
import SQLiteData
import GRDB

public enum SessionQueries {
  /// True if a session (by its `session:<id>` fingerprint) already has a canonical event.
  /// Discovery's cost guard — done before reading a transcript file.
  public static func isIngested(_ db: any DatabaseReader, sessionID: String) throws -> Bool {
    try db.read { db in
      try Event.where { $0.fingerprint.eq(Fingerprint.session(sessionID: sessionID)) }.fetchOne(db) != nil
    }
  }
}
```

- [ ] **Step 4: Implement SyncRunner**

Create `Sources/PensieveKit/Sync/SyncRunner.swift`:

```swift
import Foundation
import SQLiteData
import GRDB

/// One `sync` cycle: drain the spool, discover + spool new session transcripts, drain again,
/// then run incremental extraction. Pure over injected dependencies (spool, db, provider,
/// projectsDir, clock) so it is testable without touching the live stores or `~/.claude`.
public struct SyncRunner {
  let spool: CaptureSpool
  let db: any DatabaseWriter
  let provider: any LLMProvider
  let projectsDir: URL
  let now: @Sendable () -> Date

  public init(spool: CaptureSpool, db: any DatabaseWriter, provider: any LLMProvider,
              projectsDir: URL, now: @escaping @Sendable () -> Date = Date.init) {
    self.spool = spool; self.db = db; self.provider = provider
    self.projectsDir = projectsDir; self.now = now
  }

  public struct Summary: Sendable {
    public let ingested: Int
    public let discovered: Int
    public let extracted: Int
  }

  public func run() async throws -> Summary {
    let ingester = Ingester(spool: spool, db: db, llm: provider)
    var ingested = try await ingester.drain()

    let discovered = TranscriptDiscovery.discover(projectsDir: projectsDir, now: now()) { sessionID in
      (try? SessionQueries.isIngested(db, sessionID: sessionID)) ?? false
    }
    for url in discovered {
      try? spool.append(kind: CaptureKind.ccSession,
                        payload: try encodeJSON(SessionRefPayload(transcriptPath: url.path)))
    }
    ingested += try await ingester.drain()

    let results = try await ExtractionRunner(db: db, provider: provider).run()
    let extracted = results.reduce(0) { $0 + $1.inserted }
    return Summary(ingested: ingested, discovered: discovered.count, extracted: extracted)
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/test.sh --filter syncDiscoversIngests`
Expected: PASS.

- [ ] **Step 6: Create the `sync` command**

Create `Sources/pensieve/Commands/Sync.swift`:

```swift
import ArgumentParser
import Foundation
import PensieveKit

struct Sync: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "sync",
    abstract: "Drain the spool, discover + ingest finished/in-progress sessions, and extract loose ends.")

  func run() async throws {
    let summary = try await SyncRunner(
      spool: try openSpool(),
      db: try openCanonical(),
      provider: makeDefaultLLMProvider(),
      projectsDir: PensievePaths.claudeProjectsURL()).run()
    // ISO-timestamped so a silent daemon failure can be correlated to a time.
    print("\(Date().ISO8601Format()) sync: ingested \(summary.ingested) event(s), discovered \(summary.discovered) session(s), extracted \(summary.extracted) loose end(s)")
  }
}
```

- [ ] **Step 7: Register the command**

In `Sources/pensieve/Pensieve.swift`, add `Sync.self,` to the `subcommands:` array.

- [ ] **Step 8: Build + full suite**

Run: `swift build` then `./scripts/test.sh`
Expected: `swift build` succeeds; ALL tests PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/PensieveKit/Query/SessionQueries.swift Sources/PensieveKit/Sync/SyncRunner.swift Sources/pensieve/Commands/Sync.swift Sources/pensieve/Pensieve.swift Tests/PensieveKitTests/SyncRunnerTests.swift
git commit -F - <<'EOF'
feat: pensieve sync — drain, discover, ingest, incrementally extract

SyncRunner (pure, injected spool/db/provider/projectsDir/clock): drain ->
discover+spool new sessions -> drain -> ExtractionRunner.run(). SessionQueries
.isIngested is discovery's pre-read cost guard. Thin async `sync` subcommand
logs an ISO-timestamped per-cycle summary.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

---

### Task 9: Manual smoke test of the live daemon (no code)

**Files:** none (operational verification; do NOT set `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB` — this touches the LIVE stores).

- [ ] **Step 1: Build + install the release binary to the stable path**

```bash
swift build -c release
cp .build/release/pensieve ~/.local/bin/pensieve
```

- [ ] **Step 2: Install the SessionEnd hook and the daemon**

```bash
~/.local/bin/pensieve install-session-hook
~/.local/bin/pensieve install-daemon
```
Expected: prints that SessionEnd hook + daemon were installed.

- [ ] **Step 3: Verify the agent is loaded and the plist is correct**

```bash
launchctl print gui/$(id -u)/com.pensieve.sync | grep -E "state|program|/usr/bin"
plutil -p ~/Library/LaunchAgents/com.pensieve.sync.plist
```
Expected: state = running/waiting; `ProgramArguments[0]` is `~/.local/bin/pensieve` (absolute); `PATH` contains `/usr/bin` and no `~`.

- [ ] **Step 4: Run one cycle by hand and read the log**

```bash
~/.local/bin/pensieve sync
tail -n 3 ~/Library/Logs/Pensieve/sync.log
```
Expected: a timestamped `sync: ingested … discovered … extracted …` line; the heartbeat window (`swift run PensieveApp`) shows spool-pending falling / counts climbing.

- [ ] **Step 5: Confirm the schedule, then leave it running**

```bash
launchctl print gui/$(id -u)/com.pensieve.sync | grep -i interval
```
Expected: 300s interval. Leave installed (dogfooding). To remove: `~/.local/bin/pensieve install-daemon --uninstall`.

---

## Self-Review

**1. Spec coverage** (each spec section → task):
- §A `pensieve sync` cycle (drain → discovery → extract) → Task 8 (SyncRunner) + Task 8 command.
- §A `Ingester.drain` permanent-drop → Task 2.
- §B `TranscriptDiscovery` (already-event, 0-byte, sidechain, age-bound; no grace window) → Task 3.
- §C `capture-session-end` command → Task 4; SessionEnd installer (matcher "") → Task 5.
- §D plist writer (absolute PATH incl. /usr/bin, ProcessType Background, stable path) → Task 6; install-daemon (stable-path guard, log dir, reload-always launchctl, --uninstall) → Task 7.
- §E observability (ISO-timestamped summary; exits non-zero on throw via ArgumentParser) → Task 8 command; log rotation is a stated non-goal.
- Open constraints: `claudeProjectsURL` HOME-independent helper → Task 1; no shared static formatter (uses `Date().ISO8601Format()`) → Tasks 8; reuse existing pieces → Tasks 2/8.
- Manual launchctl smoke (spec: not unit-tested) → Task 9.

**2. Placeholder scan:** none — every code + test step is complete and concrete.

**3. Type consistency:** `SyncRunner.Summary` fields (`ingested`/`discovered`/`extracted`) match the command's `print`. `TranscriptDiscovery.discover(projectsDir:now:ageBound:alreadyIngested:)` signature matches its call in `SyncRunner`. `SessionQueries.isIngested(_:sessionID:)` (takes `any DatabaseReader`; a `DatabaseWriter` conforms) matches its call. `sessionRefFromSessionEndHook(_:)` return type (`SessionRefPayload?`) matches the command + tests. `DaemonInstaller.stablePensievePath`/`ensureStable`/`writePlist`/`load`/`unload` names match command + tests. `LaunchAgentPlist.dictionary`/`data`/`label` match tests + DaemonInstaller.

**Notes for implementers:**
- The `isSidechain` guard (Task 3) is defensive future-proofing: 0 of 371 real transcripts in `~/.claude/projects` carry `isSidechain:true` today (subagent transcripts live elsewhere), but it protects the precision gate if that changes. The synthetic test fixture exercises it.
- Task 5 keeps the existing SessionStart `install` behavior byte-for-byte (same matcher/marker/command), so pre-existing installer tests stay green; only a private helper was extracted.
- If `swift build` dies with a SwiftSyntax/macro linker error, `rm -rf .build` and retry (disk runs tight).
