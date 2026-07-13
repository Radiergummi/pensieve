# App Settings v2 + organizing-writes error surfacing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the app a tabbed Settings window (General / Intelligence / Advanced) with honest status + store-path readouts, surface the six organizing writes' failures instead of `try?`-swallowing them, and add a native About panel.

**Architecture:** One new **tested PensieveKit kernel** (`SystemStatus` / `SystemStatusGatherer`) — SwiftUI-free, never throws, every field degrades to a sensible default, all paths/defaults injected (mirrors the existing `MonitorSnapshot` gather kernel). Everything else is **app-target-only and thin**: `SettingsView` becomes a `TabView` shell over three small tab views; `AppModel` grows a `presentedError` published property that the six writes populate by classifying each command's existing return value; `RootView` mounts one `.alert`. **No trust-gate, capture, schema, or migration changes.**

**Tech Stack:** Swift 6, SwiftUI (macOS 15 deployment target), SQLiteData/GRDB, Swift Testing (`@Test`/`#expect`), XcodeGen + xcodebuild for the app target.

**Spec:** `docs/superpowers/specs/2026-07-12-app-settings-v2-error-surfacing-design.md`

## Global Constraints

- **No Python, ever. Swift only.**
- **SQLiteData predicates use `.eq(x)`, NOT `== x`** (`.where { $0.id.eq(id) }`). `==` is `unavailable` and won't compile.
- **The `Event` date column is `occurredAt`, not `at`.** ("most recent event" = `Event.order { $0.occurredAt.desc() }.limit(1).fetchOne(db)`.)
- **The app target has NO unit tests.** Only PensieveKit is unit-tested. App changes are verified by an `xcodebuild` build + a non-blocking smoke-launch of the **inner binary**.
- **Kit tests run with `./scripts/test.sh`** (or `swift test`); filter with `--filter <name>`.
- **App build:** `xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
- **Localization:** all **new app chrome** strings get German keys in `Sources/PensieveApp/Localizable.xcstrings` (impersonal/infinitive). **Never localize:** file paths, version/build numbers, provider raw kind strings, vendor names ("Anthropic", "OpenAI"), node names, loose-end quotes. **Gotcha:** `xcodebuild` does **not** auto-populate the source `.xcstrings` (IDE-only) — keys are authored **by hand** against the Swift literals.
- **Platform primitives first.** Use the current `.alert(_:isPresented:presenting:actions:message:)` API — the `Alert(title:message:dismissButton:)` value type is deprecated since macOS 12.
- **Kit code never imports SwiftUI/AppKit.** `SystemStatusGatherer` is Foundation + SQLiteData only.
- Do **not** change `ProjectResolver.group`, `NodeCommands`, or any trust-gate/extraction code.

---

## File Structure

**Create (PensieveKit — the only tested new logic):**
- `Sources/PensieveKit/Query/SystemStatus.swift` — `SystemStatus` struct + `SystemStatusGatherer.gather`. Sits next to `MonitorSnapshot.swift`, the kernel it mirrors.
- `Tests/PensieveKitTests/SystemStatusTests.swift` — deterministic tests against a temp store + temp files + an injected throwaway `UserDefaults` suite.

**Create (app target — all thin views):**
- `Sources/PensieveApp/Settings/GeneralSettingsTab.swift`
- `Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift` — the existing Intelligence + cloud logic, **moved verbatim**.
- `Sources/PensieveApp/Settings/AdvancedSettingsTab.swift`
- `Sources/PensieveApp/AppInfo.swift` — the standard About panel.

**Modify:**
- `Sources/PensieveApp/SettingsView.swift` — becomes the thin `TabView` shell (drops ~200 lines into the tab files).
- `Sources/PensieveApp/AppModel.swift` — add `AppError` + `@Published presentedError`; rewrite the six writes.
- `Sources/PensieveApp/RootView.swift` — mount the one `.alert`.
- `Sources/PensieveApp/PensieveApp.swift` — add the `CommandGroup(replacing: .appInfo)`.
- `Sources/PensieveApp/Localizable.xcstrings` — new keys (final task).

**Note on the Settings split:** the cloud subsection lives in `IntelligenceSettingsTab` **unchanged** — same `@AppStorage`/`@State`/`@FocusState`, same Keychain commit-on-submit/blur/disappear, same `rebuildSummaryBuilder()` calls, same `fetchModels()`. This is a move, not a rewrite. Any behavior change there is a bug.

---

## Task 1: `SystemStatus` Kit kernel

**Files:**
- Create: `Sources/PensieveKit/Query/SystemStatus.swift`
- Test: `Tests/PensieveKitTests/SystemStatusTests.swift`

**Interfaces:**
- Consumes: `resolvedProviderKind(defaults:cloudConfig:apiKey:)` and `FoundationModelsProbe.isAvailable()` (both existing, from `Sources/PensieveKit/LLM/DefaultProvider.swift`); `Event` (`Sources/PensieveKit/Model/Event.swift`, date column `occurredAt`).
- Produces (Task 4 depends on these exact names):
  ```swift
  public struct SystemStatus: Sendable, Equatable {
    public var providerKind: String            // "foundationModels" | "claudeCLI" | "cloud"
    public var foundationModelsAvailable: Bool
    public var daemonInstalled: Bool
    public var lastSyncAt: Date?
    public var lastEventAt: Date?
  }
  public enum SystemStatusGatherer {
    public static func gather(db: (any DatabaseReader)?,
                              defaults: UserDefaults,
                              cloudConfig: CloudConfig?,
                              apiKey: String?,
                              launchAgentURL: URL,
                              syncLogURL: URL) -> SystemStatus
  }
  ```

**Design notes for the implementer:**
- `apiKey` is `String?` (**not** an `apiKeyPresent: Bool`) so `gather` calls the shared `resolvedProviderKind` **directly** and never reimplements the "is cloud configured" test. Do not add a second resolution path.
- There is **no `now:` parameter** — every field is present-or-absent, none is relative to now. Relative-date formatting is the view's job.
- `gather` **never throws** and never creates a store: a `nil` db or a failing read degrades `lastEventAt` to `nil`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/SystemStatusTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

/// A throwaway UserDefaults suite (no provider selection ⇒ .auto ⇒ a local kind).
private func throwawayDefaults() -> (UserDefaults, String) {
  let suite = "pensieve-test-\(UUID().uuidString)"
  return (UserDefaults(suiteName: suite)!, suite)
}

@Test func gatherReportsAbsentDaemonAndEmptyStore() throws {
  let (d, suite) = throwawayDefaults()
  defer { d.removePersistentDomain(forName: suite) }
  let db = try openCanonicalDatabase(at: tempURL("status-empty"))

  let status = SystemStatusGatherer.gather(db: db, defaults: d,
                                           cloudConfig: nil, apiKey: nil,
                                           launchAgentURL: tempURL("absent", ext: "plist"),
                                           syncLogURL: tempURL("absent", ext: "log"))

  #expect(status.daemonInstalled == false)
  #expect(status.lastSyncAt == nil)
  #expect(status.lastEventAt == nil)                  // store has no events
  #expect(status.providerKind == "foundationModels" || status.providerKind == "claudeCLI")
  #expect(status.foundationModelsAvailable == FoundationModelsProbe.isAvailable())
}

@Test func gatherReportsPresentDaemonAndSyncLogMtime() throws {
  let (d, suite) = throwawayDefaults()
  defer { d.removePersistentDomain(forName: suite) }

  let plist = tempURL("agent", ext: "plist")
  try "<plist/>".write(to: plist, atomically: true, encoding: .utf8)
  let log = tempURL("sync", ext: "log")
  try "ran".write(to: log, atomically: true, encoding: .utf8)

  let status = SystemStatusGatherer.gather(db: nil, defaults: d,
                                           cloudConfig: nil, apiKey: nil,
                                           launchAgentURL: plist, syncLogURL: log)

  #expect(status.daemonInstalled == true)
  let mtime = try #require(status.lastSyncAt)
  #expect(abs(mtime.timeIntervalSinceNow) < 60)       // just written
  #expect(status.lastEventAt == nil)                  // nil db degrades, never throws
}

@Test func gatherReportsMostRecentEventTime() throws {
  let (d, suite) = throwawayDefaults()
  defer { d.removePersistentDomain(forName: suite) }
  let db = try openCanonicalDatabase(at: tempURL("status-events"))
  let resolver = ProjectResolver(db: db)
  let (node, source) = try resolver.resolve(path: "/p/one", kind: SourceKind.claudeCode)

  let old = Date(timeIntervalSince1970: 1_000_000)
  let newest = Date(timeIntervalSince1970: 2_000_000)
  try db.write { db in
    try Event.insert {
      Event(nodeID: node.id, sourceID: source.id, occurredAt: old, kind: CaptureKind.ccSession,
            summary: "old", detailJSON: "{}", fingerprint: "e1")
    }.execute(db)
    try Event.insert {
      Event(nodeID: node.id, sourceID: source.id, occurredAt: newest, kind: CaptureKind.ccSession,
            summary: "new", detailJSON: "{}", fingerprint: "e2")
    }.execute(db)
  }

  let status = SystemStatusGatherer.gather(db: db, defaults: d,
                                           cloudConfig: nil, apiKey: nil,
                                           launchAgentURL: tempURL("absent", ext: "plist"),
                                           syncLogURL: tempURL("absent", ext: "log"))

  let last = try #require(status.lastEventAt)
  #expect(abs(last.timeIntervalSince(newest)) < 1)    // the MAX, not the first row
}

@Test func gatherResolvesCloudKindWhenSelectedAndConfigured() throws {
  let (d, suite) = throwawayDefaults()
  defer { d.removePersistentDomain(forName: suite) }
  d.set(ProviderPreference.cloud.rawValue, forKey: PensieveDefaults.llmProviderKey)
  let config = CloudConfig(flavor: .anthropic,
                           baseURL: CloudFlavor.anthropic.defaultBaseURL,
                           model: "claude-sonnet-5")

  let configured = SystemStatusGatherer.gather(db: nil, defaults: d,
                                               cloudConfig: config, apiKey: "sk-test",
                                               launchAgentURL: tempURL("absent", ext: "plist"),
                                               syncLogURL: tempURL("absent", ext: "log"))
  #expect(configured.providerKind == "cloud")

  // Selected but keyless ⇒ falls back to a local kind (never "cloud"), same as the factory.
  let keyless = SystemStatusGatherer.gather(db: nil, defaults: d,
                                            cloudConfig: config, apiKey: nil,
                                            launchAgentURL: tempURL("absent", ext: "plist"),
                                            syncLogURL: tempURL("absent", ext: "log"))
  #expect(keyless.providerKind != "cloud")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter SystemStatus`
Expected: FAIL — `cannot find 'SystemStatusGatherer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PensieveKit/Query/SystemStatus.swift`:

```swift
import Foundation
import SQLiteData

/// A read-only "how is Pensieve configured and is it running?" snapshot for the Settings ▸ Advanced
/// tab. Like `MonitorSnapshot`, this is a pure gather kernel: it never throws, never writes, and
/// never creates a store — every field degrades to a sensible default rather than failing.
public struct SystemStatus: Sendable, Equatable {
  /// The RESOLVED concrete kind ("foundationModels" / "claudeCLI" / "cloud") — never a preference.
  public var providerKind: String
  public var foundationModelsAvailable: Bool
  /// The launchd LaunchAgent plist exists on disk.
  public var daemonInstalled: Bool
  /// mtime of sync.log. An honest "last daemon run": `pensieve sync` prints a summary line on EVERY
  /// run (even a no-op) and the LaunchAgent redirects stdout/stderr there, so the mtime always moves.
  public var lastSyncAt: Date?
  /// The most recent canonical `Event.occurredAt`. nil when the store is empty or unreadable.
  public var lastEventAt: Date?

  public init(providerKind: String, foundationModelsAvailable: Bool, daemonInstalled: Bool,
              lastSyncAt: Date?, lastEventAt: Date?) {
    self.providerKind = providerKind
    self.foundationModelsAvailable = foundationModelsAvailable
    self.daemonInstalled = daemonInstalled
    self.lastSyncAt = lastSyncAt
    self.lastEventAt = lastEventAt
  }
}

public enum SystemStatusGatherer {
  /// Everything is injected (db, defaults, cloud inputs, both file URLs) so this is deterministically
  /// testable against a temp store + temp files. No hidden globals, no `now:` — every field is
  /// present-or-absent, and relative-date formatting belongs to the view.
  ///
  /// `apiKey` is a `String?` (not a Bool) so we can call the SHARED `resolvedProviderKind` directly
  /// rather than reimplementing the "is cloud configured" test — one source of truth with the factory.
  public static func gather(db: (any DatabaseReader)?,
                           defaults: UserDefaults,
                           cloudConfig: CloudConfig?,
                           apiKey: String?,
                           launchAgentURL: URL,
                           syncLogURL: URL) -> SystemStatus {
    let kind = resolvedProviderKind(defaults: defaults, cloudConfig: cloudConfig, apiKey: apiKey)

    let daemonInstalled = FileManager.default.fileExists(atPath: launchAgentURL.path)

    let lastSyncAt = try? syncLogURL
      .resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate

    // Best-effort: an empty store, a read error, or a nil connection all degrade to nil.
    var lastEventAt: Date? = nil
    if let db {
      lastEventAt = try? db.read { db in
        try Event.order { $0.occurredAt.desc() }.limit(1).fetchOne(db)?.occurredAt
      }
    }

    return SystemStatus(providerKind: kind,
                        foundationModelsAvailable: FoundationModelsProbe.isAvailable(),
                        daemonInstalled: daemonInstalled,
                        lastSyncAt: lastSyncAt ?? nil,
                        lastEventAt: lastEventAt ?? nil)
  }
}
```

> Note the double-optional flattening: `try?` over an expression that is already `Date?` yields `Date??`. The `?? nil` collapses it. If the compiler disagrees about the exact shape, bind with `if let` rather than force-unwrapping.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter SystemStatus`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full suite (no regressions)**

Run: `./scripts/test.sh`
Expected: all tests pass; total count = previous total + 4.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Query/SystemStatus.swift Tests/PensieveKitTests/SystemStatusTests.swift
git commit -m "feat(kit): SystemStatus gather kernel for the Settings Advanced tab"
```

---

## Task 2: Organizing-writes error surfacing

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift` (the `setLooseEndLabel` + "Organizing writes" region, ~lines 508–590)
- Modify: `Sources/PensieveApp/RootView.swift` (mount the alert in `body`)

**Interfaces:**
- Consumes: existing Kit returns — `NodeCommands.add → Node?`, `NodeCommands.update → Bool`, `NodeCommands.reparent → Bool`, `NodeCommands.delete → DeleteResult (.deleted/.blocked/.notFound)`, `LooseEndCommands.setLabel → Bool`, `ProjectResolver.group → Void`.
- Produces: `AppError` (`title`, `message`) + `@Published var presentedError: AppError?` on `AppModel`.

**The two rules that make this correct — do not skip:**

1. **A refusal must still `refresh()`.** Every refusal is *by definition* a stale-view problem (the node changed under the menu). Refreshing is the remedy: it makes the phantom node disappear and makes the "try again" copy true. Skip only the post-write **state** changes (selection moves). **A throw does NOT refresh** — a DB error says nothing about staleness.
2. **`merge` needs an existence pre-check.** `ProjectResolver.group` never validates that the target exists. There is no data-loss hazard (FKs + a single `db.write` abort the whole transaction), but it aborts by *throwing an FK violation* whose `localizedDescription` is `"FOREIGN KEY constraint failed"` — piping that into an alert would give the one **destructive** op the worst copy in the app. So fetch both nodes first and emit the normal refusal copy if either is gone. **Do not modify `group`.**

- [ ] **Step 1: Add `AppError` and the published property**

In `Sources/PensieveApp/AppModel.swift`, above the `AppModel` class (near the other small app types):

```swift
/// A user-facing failure from an organizing write. Two flavors, both surfaced the same way:
/// a REFUSAL (the command returned a non-success value — stale/guarded state) and a THROW (a real
/// DB error). Refusals get honest, non-alarming copy; throws append the underlying description.
struct AppError: Identifiable {
  let id = UUID()
  let title: String
  let message: String

  /// The node changed under the menu (deleted or re-parented between open and click).
  static func refusal(_ verb: String, _ name: String) -> AppError {
    AppError(title: String(localized: "Couldn’t \(verb) “\(name)”"),
             message: String(localized: "It may have changed since this menu opened. The view has been refreshed — try again."))
  }

  static func failure(_ verb: String, _ name: String, _ error: Error) -> AppError {
    AppError(title: String(localized: "Couldn’t \(verb) “\(name)”"),
             message: error.localizedDescription)
  }
}
```

Add to the `@Published` block on `AppModel` (next to `pendingDeleteNodeID`):

```swift
  /// The one surfaced organizing-write failure. Mounted as a single `.alert` in RootView.
  @Published var presentedError: AppError?
```

- [ ] **Step 2: Add the two small helpers**

Add to `AppModel`, immediately above the "Organizing writes" MARK comment:

```swift
  /// A refusal: the view was stale, so REFRESH (that's the remedy — the phantom node disappears and
  /// the "try again" copy becomes true), then surface the alert. Post-write state changes are skipped.
  private func refuse(_ verb: String, _ name: String) {
    refresh()
    presentedError = .refusal(verb, name)
  }

  /// A throw: a real DB error. Do NOT refresh — an error tells us nothing about staleness.
  private func fail(_ verb: String, _ name: String, _ error: Error) {
    presentedError = .failure(verb, name, error)
  }

  /// The display name for a node id, falling back to a neutral word when it's already gone.
  private func displayName(_ id: UUID) -> String {
    node(id)?.name ?? String(localized: "this item")
  }
```

- [ ] **Step 3: Rewrite the six writes**

Replace `setLooseEndLabel` and the five organizing writes in `Sources/PensieveApp/AppModel.swift` with these. Every `try?` is gone; every outcome is classified.

```swift
  /// Confirm a user salience label for a loose end (👍 salient / 👎 noise / "" clears).
  func setLooseEndLabel(_ looseEndID: UUID, _ label: String) {
    guard let db else { return }
    do {
      let ok = try LooseEndCommands.setLabel(db, id: looseEndID, label: label)
      if !ok { refuse(String(localized: "update"), String(localized: "this loose end")) }
    } catch {
      fail(String(localized: "update"), String(localized: "this loose end"), error)
    }
  }
```

```swift
  /// Commit the New Node modal: insert fully-formed, select it.
  func commitNewNode(parent parentID: UUID?, name: String, kind: String,
                     icon: String, colorTag: String, context: String) {
    guard let db else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      // nil ⇒ the parent id didn't resolve (deleted under the menu). Name the PARENT: the new node
      // doesn't exist yet, so its own name would be meaningless in the copy.
      guard let new = try NodeCommands.add(db, name: trimmed, kind: kind,
                                           parent: parentID?.uuidString, description: "",
                                           icon: icon, colorTag: colorTag, context: context) else {
        let parentName = parentID.map { displayName($0) } ?? String(localized: "the top level")
        refuse(String(localized: "add a node under"), parentName)
        return
      }
      refresh()
      sidebarSelection = .node(new.id); selectedNodeID = new.id
    } catch {
      fail(String(localized: "create"), trimmed, error)
    }
  }

  /// Commit the Edit modal: atomic name/kind/icon/colorTag update.
  func updateNode(_ nodeID: UUID, name: String, kind: String,
                  icon: String, colorTag: String, context: String) {
    guard let db else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let label = displayName(nodeID)
    do {
      let ok = try NodeCommands.update(db, nodeID: nodeID, name: trimmed, kind: kind,
                                       icon: icon, colorTag: colorTag, context: context)
      if ok { refresh() } else { refuse(String(localized: "rename"), label) }
    } catch {
      fail(String(localized: "rename"), label, error)
    }
  }

  func move(_ nodeID: UUID, under newParentID: UUID?) {
    guard let db else { return }
    let label = displayName(nodeID)
    do {
      // false ⇒ cycle guard, unknown node, or unknown parent — all stale-state rejections.
      let ok = try NodeCommands.reparent(db, nodeID: nodeID, newParentID: newParentID)
      if ok { refresh() } else { refuse(String(localized: "move"), label) }
    } catch {
      fail(String(localized: "move"), label, error)
    }
  }

  /// Merge `sourceID` into `targetID`. `ProjectResolver.group` returns Void and never validates that
  /// the TARGET still exists: a concurrently-deleted target aborts the whole transaction on an FK
  /// violation (no data loss — but "FOREIGN KEY constraint failed" is not copy we show a human). So
  /// pre-check both nodes and emit the normal refusal instead. `group` itself stays untouched.
  func merge(_ sourceID: UUID, into targetID: UUID) {
    guard let db, sourceID != targetID else { return }
    let label = displayName(sourceID)

    let bothExist = (try? db.read { db in
      try Node.where { $0.id.eq(sourceID) }.fetchOne(db) != nil
        && Node.where { $0.id.eq(targetID) }.fetchOne(db) != nil
    }) ?? false
    guard bothExist else { refuse(String(localized: "merge"), label); return }

    do {
      try ProjectResolver(db: db).group(targetID, into: [sourceID])
      // The source node is gone: move any state that referenced it onto the survivor.
      if selectedNodeID == sourceID { selectedNodeID = targetID }
      if sidebarSelection == .node(sourceID) { sidebarSelection = .node(targetID) }
      refresh()
    } catch {
      fail(String(localized: "merge"), label, error)
    }
  }

  /// Delete a (source-free) node and its subtree via the Kit cascade. Moves selection off it.
  func deleteNode(_ nodeID: UUID) {
    guard let db else { return }
    let label = displayName(nodeID)
    do {
      switch try NodeCommands.delete(db, nodeID: nodeID) {
      case .deleted:
        if selectedNodeID == nodeID { selectedNodeID = nil }
        if sidebarSelection == .node(nodeID) { sidebarSelection = .briefing }
        refresh()
      case .blocked:
        // The subtree is activity-born — it would resurrect on the next sync. `canDelete` already
        // gates the menu, so this only fires on a stale menu; the copy names the real reason.
        refresh()
        presentedError = AppError(
          title: String(localized: "Can’t delete “\(label)”"),
          message: String(localized: "It still has captured sources or activity that would return on the next sync."))
      case .notFound:
        refuse(String(localized: "delete"), label)
      }
    } catch {
      fail(String(localized: "delete"), label, error)
    }
  }
```

> `merge`'s pre-check needs `Node` and `.eq` in scope — `AppModel.swift` already imports `SQLiteData`, `GRDB`, and `PensieveKit`, so no new imports.

- [ ] **Step 4: Mount the single alert in `RootView`**

In `Sources/PensieveApp/RootView.swift`, add to the modifier chain on `NavigationSplitView` — put it directly **after** the existing `.confirmationDialog(...)` block, as the last modifier before the closing brace of `body`:

```swift
    .alert(
      model.presentedError?.title ?? "",
      isPresented: Binding(get: { model.presentedError != nil },
                           set: { if !$0 { model.presentedError = nil } }),
      presenting: model.presentedError
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { err in
      Text(err.message)
    }
```

> This is the current API. Do **not** use `Alert(title:message:dismissButton:)` — deprecated since macOS 12.
> `AppError.title`/`.message` are already-localized `String`s (built with `String(localized:)`), so pass them
> straight to `Text` — do **not** re-wrap them in `LocalizedStringKey`.

- [ ] **Step 5: Build the app**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve \
  -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Smoke-launch the inner binary (non-blocking, throwaway stores)**

```bash
PENSIEVE_DB=/tmp/smoke-$$.sqlite PENSIEVE_CAPTURE_DB=/tmp/smoke-cap-$$.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 3; kill $PID
```
Expected: no crash within 3 s (it launches, renders, exits on kill).

- [ ] **Step 7: Run the Kit suite (no regressions)**

Run: `./scripts/test.sh`
Expected: all pass (this task changes no Kit code — the count is unchanged from Task 1).

- [ ] **Step 8: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/RootView.swift
git commit -m "feat(app): surface organizing-write failures instead of swallowing them"
```

---

## Task 3: Tabbed Settings shell (General + Intelligence)

**Files:**
- Create: `Sources/PensieveApp/Settings/GeneralSettingsTab.swift`
- Create: `Sources/PensieveApp/Settings/IntelligenceSettingsTab.swift`
- Modify: `Sources/PensieveApp/SettingsView.swift` (becomes the `TabView` shell)

**Interfaces:**
- Consumes: `AppModel.rebuildSummaryBuilder()`, `AppDefaults.hideDockIconKey` / `.narrationEnabledKey`, `PensieveDefaults.llmProviderKey` / `.cloudFlavorKey` / `.cloudBaseURLKey` / `.cloudModelKey`, `CloudPresets`, `CloudConfig`, `CloudLLMProvider.listModels`, `KeychainSecretStore`, `FoundationModelsProbe` — all existing.
- Produces: `GeneralSettingsTab(model:)`, `IntelligenceSettingsTab(model:)`. Task 4 adds `AdvancedSettingsTab(model:)` to the same shell.

**This task is a MOVE, not a rewrite.** The Intelligence tab must keep the cloud subsection's behavior **byte-for-byte**: the same `@AppStorage`/`@State`/`@FocusState` properties, the same Keychain commit on submit / blur / disappear, the same `resetCloudFieldsForVendorChange` / `reloadKeyForAccount` / `commitKey` / `fetchModels` / `modelOptions` / `canFetch` / `vendorSelection`, the same `model.rebuildSummaryBuilder()` call sites. Any behavior change here is a bug.

- [ ] **Step 1: Create `GeneralSettingsTab`**

```swift
import SwiftUI
import AppKit
import PensieveKit

/// Settings ▸ General. Intentionally short — standard macOS General tabs often are.
struct GeneralSettingsTab: View {
  @AppStorage(AppDefaults.hideDockIconKey) private var hideDockIcon = false

  var body: some View {
    Form {
      Section {
        Toggle("Hide Dock icon (menu bar only)", isOn: $hideDockIcon)
          .onChange(of: hideDockIcon) { _, hidden in
            NSApp.setActivationPolicy(hidden ? .accessory : .regular)
            if !hidden { NSApp.activate(ignoringOtherApps: true) }
          }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
  }
}
```

- [ ] **Step 2: Create `IntelligenceSettingsTab` by moving the existing code**

Move — unchanged — from `SettingsView.swift`: the `@AppStorage` provider/cloud properties, `apiKeyField`, `loadedKey`, `models`, `isFetching`, `fetchError`, `vendorIsCustom`, all three `@FocusState`s, `foundationAvailable`, `cloudFlavor`, `keychainAccount`, `provider`, `label(for:)`, `help(for:)`, `cloudSection`, `modelOptions`, `canFetch`, `vendorSelection`, `resetCloudFieldsForVendorChange()`, `reloadKeyForAccount()`, `commitKey()`, `fetchModels()`, and the `.onAppear` that seeds the Keychain field.

```swift
import SwiftUI
import PensieveKit

/// Settings ▸ Intelligence. The narration toggle, the provider picker, and the cloud subsection —
/// moved verbatim out of the old single-Form SettingsView and given vertical room. Reads/writes
/// preferences via @AppStorage; the only AppModel touch is rebuilding its summary builder on change.
struct IntelligenceSettingsTab: View {
  @ObservedObject var model: AppModel
  @AppStorage(PensieveDefaults.llmProviderKey) private var providerRaw = ProviderPreference.auto.rawValue
  @AppStorage(AppDefaults.narrationEnabledKey) private var narrationEnabled = true

  @AppStorage(PensieveDefaults.cloudFlavorKey) private var cloudFlavorRaw = CloudFlavor.anthropic.rawValue
  @AppStorage(PensieveDefaults.cloudBaseURLKey) private var cloudBaseURL = ""
  @AppStorage(PensieveDefaults.cloudModelKey) private var cloudModel = ""

  @State private var apiKeyField = ""
  /// Mirrors the last-persisted Keychain value, so an edited-but-unsubmitted key is distinguishable
  /// from an unchanged one (skips a redundant Keychain write / re-auth prompt).
  @State private var loadedKey = ""
  @State private var models: [String] = []
  @State private var isFetching = false
  @State private var fetchError = false
  @State private var vendorIsCustom = false

  @FocusState private var keyFocused: Bool
  @FocusState private var baseURLFocused: Bool
  @FocusState private var modelFocused: Bool

  var body: some View {
    Form {
      Section {
        Toggle("Show “Last Work Done” narration", isOn: $narrationEnabled)

        Picker("LLM Provider", selection: provider) {
          ForEach([ProviderPreference.auto, .foundationModels, .claudeCLI, .cloud], id: \.self) { p in
            Text(label(for: p)).tag(p)
          }
        }
        .onChange(of: providerRaw) { _, _ in
          if provider.wrappedValue == .cloud, cloudBaseURL.isEmpty { cloudBaseURL = cloudFlavor.defaultBaseURL }
          model.rebuildSummaryBuilder()
        }

        Label(help(for: provider.wrappedValue), systemImage: "info.circle")
          .font(.caption).foregroundStyle(.secondary)

        if provider.wrappedValue == .foundationModels && !foundationAvailable {
          Label("Foundation Models isn’t available on this Mac — using claude -p instead.",
                systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.secondary)
        }
      }

      if provider.wrappedValue == .cloud {
        Section("Cloud provider") { cloudSection }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .onAppear {
      apiKeyField = KeychainSecretStore().read(account: keychainAccount) ?? ""
      loadedKey = apiKeyField
    }
  }

  // ... everything below is moved VERBATIM from the old SettingsView: foundationAvailable,
  // cloudFlavor, keychainAccount, provider, label(for:), help(for:), cloudSection, modelOptions,
  // canFetch, vendorSelection, resetCloudFieldsForVendorChange, reloadKeyForAccount, commitKey,
  // fetchModels. Copy them across unchanged.
}
```

> The one intentional difference from the old layout: the cloud fields now sit in their own
> `Section("Cloud provider")` instead of being crammed into the Intelligence section. Everything
> inside `cloudSection` is unchanged.

- [ ] **Step 3: Reduce `SettingsView` to the TabView shell**

Replace the whole body of `Sources/PensieveApp/SettingsView.swift`:

```swift
import SwiftUI
import PensieveKit

/// The app's Settings pane (⌘,) — a native multi-pane TabView, the first-party settings pattern.
/// The window sizes to the visible tab; each tab carries its own .frame(width: 460).
struct SettingsView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    TabView {
      GeneralSettingsTab()
        .tabItem { Label("General", systemImage: "gearshape") }
      IntelligenceSettingsTab(model: model)
        .tabItem { Label("Intelligence", systemImage: "sparkles") }
      AdvancedSettingsTab(model: model)
        .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
    }
  }
}
```

> `AdvancedSettingsTab` doesn't exist until Task 4. To keep this task independently buildable, add a
> placeholder file `Sources/PensieveApp/Settings/AdvancedSettingsTab.swift` **in this task** containing
> only the struct shell below; Task 4 fills in its body.
>
> ```swift
> import SwiftUI
> import PensieveKit
>
> struct AdvancedSettingsTab: View {
>   @ObservedObject var model: AppModel
>   var body: some View {
>     Form { }
>       .formStyle(.grouped)
>       .frame(width: 460)
>   }
> }
> ```

- [ ] **Step 4: Regenerate the project and build**

New files under `Sources/PensieveApp/` are picked up by XcodeGen's directory-based source globbing, so no `project.yml` edit is needed — but the project **must** be regenerated.

```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve \
  -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Smoke-launch**

```bash
PENSIEVE_DB=/tmp/smoke-$$.sqlite PENSIEVE_CAPTURE_DB=/tmp/smoke-cap-$$.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 3; kill $PID
```
Expected: no crash.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/SettingsView.swift Sources/PensieveApp/Settings/
git commit -m "refactor(app): split Settings into a native tabbed shell (General + Intelligence)"
```

---

## Task 4: Advanced tab — status + store paths

**Files:**
- Modify: `Sources/PensieveApp/Settings/AdvancedSettingsTab.swift` (fill in the Task 3 placeholder)

**Interfaces:**
- Consumes: `SystemStatus` / `SystemStatusGatherer.gather(db:defaults:cloudConfig:apiKey:launchAgentURL:syncLogURL:)` (Task 1); `Stores.canonicalURL` / `Stores.spoolURL` (app-target enum in `PensieveApp.swift`, honors the `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` env overrides); `PensievePaths.supportDirectory()` / `.logsDirectory()` / `.launchAgentURL()` / `.syncLogURL()`; `AppModel.db`.
- Produces: nothing consumed downstream.

**The `AppModel.db` access:** the gatherer takes `(any DatabaseReader)?`. `AppModel.db` is the app's existing canonical connection (an `any DatabaseWriter`, which conforms to `DatabaseReader`). If `db` is `private` on `AppModel`, widen it to `internal` (same module) — do **not** open a second connection here: opening a fresh connection touches the store's `-wal`/`-shm` sidecars and re-fires the directory watch into a busy-loop (the exact bug called out in `AppModel.refresh`).

- [ ] **Step 1: Write the Advanced tab**

```swift
import SwiftUI
import AppKit
import PensieveKit

/// Settings ▸ Advanced. A read-only glance: resolved provider, daemon/sync status, and the store
/// paths. Reads the tested `SystemStatusGatherer` kernel once on appear — no live observation, and
/// it never mutates the daemon (installing/editing it is a separate, later spec).
struct AdvancedSettingsTab: View {
  @ObservedObject var model: AppModel
  @AppStorage(PensieveDefaults.cloudFlavorKey) private var cloudFlavorRaw = CloudFlavor.anthropic.rawValue
  @AppStorage(PensieveDefaults.cloudBaseURLKey) private var cloudBaseURL = ""
  @AppStorage(PensieveDefaults.cloudModelKey) private var cloudModel = ""

  @State private var status: SystemStatus?

  var body: some View {
    Form {
      Section("Status") {
        LabeledContent("LLM provider") { Text(providerDisplayName) }
        if let status, !status.foundationModelsAvailable {
          Label("Foundation Models isn’t available on this Mac.", systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
        }
        LabeledContent("Sync daemon") {
          Text(status?.daemonInstalled == true ? "Installed" : "Not installed")
        }
        LabeledContent("Last sync") { Text(relative(status?.lastSyncAt)) }
        LabeledContent("Last captured activity") { Text(relative(status?.lastEventAt)) }
      }

      Section("Store & Logs") {
        pathRow("Canonical store", Stores.canonicalURL)
        pathRow("Capture spool", Stores.spoolURL)
        pathRow("Support folder", PensievePaths.supportDirectory())
        pathRow("Logs", PensievePaths.logsDirectory())
        Button("Open Logs Folder") {
          NSWorkspace.shared.open(PensievePaths.logsDirectory())
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .onAppear(perform: load)
  }

  /// A full store path does NOT fit 460 pt — truncate in the middle and put the whole path in a
  /// tooltip, so the row can never blow out the window.
  @ViewBuilder private func pathRow(_ title: LocalizedStringKey, _ url: URL) -> some View {
    LabeledContent(title) {
      HStack(spacing: 8) {
        Text(url.path)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(url.path)
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .buttonStyle(.link)
        .fixedSize()
      }
    }
  }

  private func load() {
    let config = CloudConfig(flavor: CloudFlavor(rawValue: cloudFlavorRaw) ?? .anthropic,
                             baseURL: cloudBaseURL, model: cloudModel)
    let key = KeychainSecretStore().read(
      account: CloudPresets.keychainAccount(flavor: config.flavor, baseURL: cloudBaseURL))
    status = SystemStatusGatherer.gather(db: model.db,
                                         defaults: .standard,
                                         cloudConfig: config,
                                         apiKey: key,
                                         launchAgentURL: PensievePaths.launchAgentURL(),
                                         syncLogURL: PensievePaths.syncLogURL())
  }

  /// The RESOLVED kind, in human words. The raw kind strings are never shown and never localized.
  private var providerDisplayName: LocalizedStringKey {
    switch status?.providerKind {
    case "foundationModels": return "On-device (Foundation Models)"
    case "claudeCLI": return "Claude CLI (subscription)"
    case "cloud": return "Cloud (API)"
    default: return "—"
    }
  }

  /// An honest em-dash-free absent value: "Never" reads as a fact, not a formatting failure.
  private func relative(_ date: Date?) -> String {
    guard let date else { return String(localized: "Never") }
    return date.formatted(.relative(presentation: .named))
  }
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve \
  -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: `** BUILD SUCCEEDED **`. If it fails with `'db' is inaccessible due to 'private' protection level`, widen `AppModel.db` to internal (drop the `private`) and rebuild.

- [ ] **Step 3: Smoke-launch**

```bash
PENSIEVE_DB=/tmp/smoke-$$.sqlite PENSIEVE_CAPTURE_DB=/tmp/smoke-cap-$$.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
PID=$!; sleep 3; kill $PID
```
Expected: no crash.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/Settings/AdvancedSettingsTab.swift Sources/PensieveApp/AppModel.swift
git commit -m "feat(app): Settings Advanced tab — status readouts + store paths"
```

---

## Task 5: Native About panel

**Files:**
- Create: `Sources/PensieveApp/AppInfo.swift`
- Modify: `Sources/PensieveApp/PensieveApp.swift` (the `.commands` block)

**Interfaces:**
- Consumes: `Bundle.main.infoDictionary`.
- Produces: `AppInfo.showAboutPanel()`.

- [ ] **Step 1: Create `AppInfo`**

```swift
import AppKit

/// The standard macOS About panel — the first-party primitive, not a hand-built window.
enum AppInfo {
  static func showAboutPanel() {
    let credits = NSAttributedString(
      string: String(localized: "A personal tool for reloading context across parallel projects. Not a product."),
      attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        .foregroundColor: NSColor.secondaryLabelColor,
      ])

    // Version/build come from the bundle and are NEVER localized.
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? ""
    let build = info?["CFBundleVersion"] as? String ?? ""

    NSApplication.shared.orderFrontStandardAboutPanel(options: [
      .applicationName: "Pensieve",
      .applicationVersion: version,
      .version: build,
      .credits: credits,
    ])
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}
```

- [ ] **Step 2: Replace the About menu item**

In `Sources/PensieveApp/PensieveApp.swift`, add as the **first** entry inside the existing `.commands { ... }` block (before `SidebarCommands()`):

```swift
      CommandGroup(replacing: .appInfo) {
        Button("About Pensieve") { AppInfo.showAboutPanel() }
      }
```

- [ ] **Step 3: Build**

```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve \
  -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Sources/PensieveApp/AppInfo.swift Sources/PensieveApp/PensieveApp.swift
git commit -m "feat(app): native About Pensieve panel"
```

---

## Task 6: German localization of all new chrome

**Files:**
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: every `String(localized:)` / `LocalizedStringKey` literal added in Tasks 2–5.

**Critical gotcha (this is why it's its own task):** `xcodebuild … build` does **NOT** auto-populate the source `.xcstrings` with extracted keys — that's IDE-only. Keys must be **authored by hand**, and the key string must match the Swift literal **exactly** (including the typographic quotes `“ ”` and the `%@`/`%lld` format specifiers). A mis-keyed `de` value silently falls back to English — it does not error.

- [ ] **Step 1: Collect every new literal**

Run this to list the literals introduced by this branch (review the output — it is the authoritative key list):

```bash
git diff main --unified=0 -- Sources/PensieveApp \
  | grep '^+' \
  | grep -oE 'String\(localized: "[^"]+"\)|Text\("[^"]+"\)|Label\("[^"]+"|Toggle\("[^"]+"|Section\("[^"]+"|LabeledContent\("[^"]+"|Button\("[^"]+"|\.tabItem|"[A-Z][^"]{3,}"' \
  | sort -u
```

Expected new keys (verify against the command's output; add any it surfaces that aren't here):

| English key | German (`de`) |
|---|---|
| `General` | `Allgemein` |
| `Intelligence` | `Intelligenz` |
| `Advanced` | `Erweitert` |
| `Cloud provider` | `Cloud-Anbieter` |
| `Status` | `Status` |
| `LLM provider` | `LLM-Anbieter` |
| `Foundation Models isn’t available on this Mac.` | `Foundation Models ist auf diesem Mac nicht verfügbar.` |
| `Sync daemon` | `Sync-Dienst` |
| `Installed` | `Installiert` |
| `Not installed` | `Nicht installiert` |
| `Last sync` | `Letzte Synchronisierung` |
| `Last captured activity` | `Zuletzt erfasste Aktivität` |
| `Never` | `Nie` |
| `Store & Logs` | `Speicher & Protokolle` |
| `Canonical store` | `Kanonischer Speicher` |
| `Capture spool` | `Erfassungs-Spool` |
| `Support folder` | `Support-Ordner` |
| `Logs` | `Protokolle` |
| `Reveal in Finder` | `Im Finder zeigen` |
| `Open Logs Folder` | `Protokollordner öffnen` |
| `About Pensieve` | `Über Pensieve` |
| `A personal tool for reloading context across parallel projects. Not a product.` | `Ein persönliches Werkzeug, um den Kontext paralleler Projekte wiederherzustellen. Kein Produkt.` |
| `OK` | `OK` |
| `this item` | `dieses Element` |
| `this loose end` | `dieser offene Punkt` |
| `the top level` | `die oberste Ebene` |
| `Couldn’t %@ “%@”` | `„%2$@“ konnte nicht %1$@ werden` |
| `It may have changed since this menu opened. The view has been refreshed — try again.` | `Es hat sich möglicherweise geändert, seit dieses Menü geöffnet wurde. Die Ansicht wurde aktualisiert — bitte erneut versuchen.` |
| `Can’t delete “%@”` | `„%@“ kann nicht gelöscht werden` |
| `It still has captured sources or activity that would return on the next sync.` | `Es hat noch erfasste Quellen oder Aktivität, die bei der nächsten Synchronisierung zurückkehren würden.` |
| `add a node under` | `hinzufügen unter` |
| `create` | `erstellt` |
| `rename` | `umbenannt` |
| `move` | `verschoben` |
| `merge` | `zusammengeführt` |
| `delete` | `gelöscht` |
| `update` | `aktualisiert` |

> **Verb-interpolation caveat.** `AppError.refusal(_ verb:_ name:)` interpolates a verb into `"Couldn’t \(verb) “\(name)”"`. That composes cleanly in English but is fragile in German (verb position and inflection differ). If the German reads badly in situ, the correct fix is to **stop composing** — give each of the six writes its own complete, separately-keyed title (`"Couldn’t move “%@”"`, `"Couldn’t merge “%@”"`, …) rather than fighting the interpolation. Flag this on the human-verify pass; do not silently ship an awkward string.

- [ ] **Step 2: Add the keys to `Localizable.xcstrings`**

Follow the existing entry shape exactly (`"extractionState": "manual"`, an `en` and a `de` `stringUnit`, `"state": "translated"`). Do **not** add keys for: file paths, version/build numbers, provider raw kind strings, or vendor names.

- [ ] **Step 3: Verify the catalog is valid JSON and compiles into the bundle**

```bash
plutil -lint Sources/PensieveApp/Localizable.xcstrings
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve \
  -configuration Debug -derivedDataPath ./.build-xcode build
ls ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -i "Erweitert\|Sync-Dienst"
```
Expected: lint OK; `** BUILD SUCCEEDED **`; `de.lproj/Localizable.strings` exists; the grep prints the German values (if a key is missing, it silently falls back to English — that's the failure mode to catch here).

- [ ] **Step 4: Launch in German and check the new chrome in situ**

```bash
open ./.build-xcode/Build/Products/Debug/Pensieve.app --args -AppleLanguages '(de)'
```
Open ⌘, and check all three tabs. Paths, version numbers, and vendor names must stay English/untranslated.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/Localizable.xcstrings
git commit -m "feat(app): German localization for Settings v2 + error alerts"
```

---

## Final verification

- [ ] `./scripts/test.sh` — full Kit suite passes; total = previous + 4 (the `SystemStatus` tests).
- [ ] `xcodegen generate && xcodebuild … build` — `** BUILD SUCCEEDED **`.
- [ ] Smoke-launch the inner binary with throwaway stores — no crash.
- [ ] `git diff main --stat` — every changed file traces to a task above. No trust-gate, capture, extraction, schema, or migration file appears.

## Human-verify carries (need the built app, a real store, and a plain `open`)

These cannot be verified by an agent — they need the real app against the real store. Record the results.

- ⌘, opens a **tabbed** window; General / Intelligence / Advanced switch; each knob persists across relaunch.
- The cloud subsection is **fully functional in its new home**: Fetch models works, the key persists (submit / blur / close), the model resets on a vendor switch, and switching provider takes effect without relaunch.
- Advanced shows the resolved provider, the FM-availability note, daemon Installed/Not installed, and honest last-sync / last-activity times ("Never" when absent). Reveal-in-Finder opens each of the four paths; Open Logs Folder works. **No path overflows the window.**
- **Force a refused write** (delete a node in a second window, then act on it from a stale context menu in the first): the alert appears with honest copy, the op does nothing, **and dismissing it leaves a refreshed tree** — the phantom node is gone, so "try again" is not an infinite loop.
- **Force a stale merge** (delete the merge *target* in a second window, then merge into it from a stale menu): the honest refusal copy appears — **never** a raw `"FOREIGN KEY constraint failed"`.
- A normal New / Rename / Move / Merge / Delete still succeeds **silently** (no alert on the happy path).
- "About Pensieve" in the app menu shows the version/build and the credit line.
- German in situ (`-AppleLanguages '(de)'`) for all new chrome — **especially the six error titles** (see the verb-interpolation caveat in Task 6).
