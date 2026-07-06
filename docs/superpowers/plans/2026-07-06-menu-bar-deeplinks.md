# Menu-bar item + `pensieve://` deep links (v0.2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a menu-bar status item to `Pensieve.app` — a rich popover showing the capture heartbeat + a short What's Next glance with click-to-jump — and register a minimal, tested `pensieve://` deep-link scheme as its first consumer.

**Architecture:** A second SwiftUI `MenuBarExtra` scene lives in the same app alongside the existing `Window`, sharing the one `AppModel`. A tested `DeepLink` value type (PensieveKit) parses/serializes `pensieve://` URLs. Internal menu-bar clicks apply navigation in-process; external `pensieve://` opens arrive via a scene-independent `NSApplicationDelegateAdaptor` and funnel through one `applyDeepLink` helper hosted on the always-mounted menu-bar label. Views stay thin; all derivation is the already-tested `MonitorSnapshot` / `SmartLists` kernels.

**Tech Stack:** Swift 6, SwiftUI (`MenuBarExtra`, `@Environment(\.openWindow)`, `NSApplicationDelegateAdaptor`), AppKit (`NSApplicationDelegate`), Swift Testing, SQLiteData, XcodeGen + Xcode 26.6.

## Global Constraints

- **Deployment target macOS 14.0** — `MenuBarExtra` / `.menuBarExtraStyle(.window)` (13+), `openWindow` (13+), `.onChange(of:) { old, new in }` two-param form (14+), `NSApplication.activate()` cooperative form (14+) are all available. Do **not** use `activate(ignoringOtherApps:)` (deprecated in 14).
- **URL scheme is `pensieve`.** `DeepLink.SmartList` raw values MUST equal the app's `SmartListKind` raw values (`whatsNext` / `dormant` / `recentlyActive`).
- **Derivation lives in tested PensieveKit; views stay thin.** Only `DeepLink` (PensieveKit) is unit-tested. The **app target (`Sources/PensieveApp/`) has no unit tests** — verify app tasks with `xcodebuild` build + a non-blocking smoke-launch of the inner binary, and keep the full suite green.
- **No shared mutable `static` `RelativeDateTimeFormatter`/`ISO8601DateFormatter`** (Swift 6) — use a local instance.
- SQLiteData predicates use `.eq(x)`, not `== x` (not needed here, but the rule holds).
- **The app is built by XcodeGen + Xcode**, not `swift run`. Build:
  ```
  xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve \
    -configuration Debug -derivedDataPath ./.build-xcode build
  ```
  App at `./.build-xcode/Build/Products/Debug/Pensieve.app`; smoke-launch the **inner binary** `…/Contents/MacOS/Pensieve` (forwards `PENSIEVE_DB`/`PENSIEVE_CAPTURE_DB`).
- **Commit messages: no backticks in `-m` (they shell-execute).** Use plain text or `git commit -F`. Keep the `Co-Authored-By:` + `Claude-Session:` trailers per repo convention.
- Run the full test suite with `./scripts/test.sh`.

---

### Task 1: `DeepLink` router (PensieveKit, unit-tested)

**Files:**
- Create: `Sources/PensieveKit/Support/DeepLink.swift`
- Test: `Tests/PensieveKitTests/DeepLinkTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces:
  - `public enum DeepLink: Equatable, Sendable { case briefing; case node(UUID); case smartList(SmartList) }`
  - `public enum DeepLink.SmartList: String, Equatable, Sendable { case whatsNext, dormant, recentlyActive }`
  - `public init?(url: URL)` and `public var url: URL` (round-trips: `DeepLink(url: link.url) == link`)
  - `public static let scheme = "pensieve"`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PensieveKitTests/DeepLinkTests.swift`:

```swift
import Foundation
import Testing
@testable import PensieveKit

@Test func deepLinkRoundTripsBriefing() {
  let link = DeepLink.briefing
  #expect(DeepLink(url: link.url) == link)
  #expect(link.url.absoluteString == "pensieve://briefing")
}

@Test func deepLinkRoundTripsNode() {
  let link = DeepLink.node(UUID())
  #expect(DeepLink(url: link.url) == link)
}

@Test func deepLinkRoundTripsEverySmartList() {
  for kind in [DeepLink.SmartList.whatsNext, .dormant, .recentlyActive] {
    let link = DeepLink.smartList(kind)
    #expect(DeepLink(url: link.url) == link)
  }
}

@Test func deepLinkParsesKnownForms() {
  #expect(DeepLink(url: URL(string: "pensieve://briefing")!) == .briefing)
  #expect(DeepLink(url: URL(string: "pensieve://smartlist/dormant")!) == .smartList(.dormant))
  let id = UUID()
  #expect(DeepLink(url: URL(string: "pensieve://node/\(id.uuidString)")!) == .node(id))
}

@Test func deepLinkRejectsMalformed() {
  #expect(DeepLink(url: URL(string: "http://briefing")!) == nil)            // wrong scheme
  #expect(DeepLink(url: URL(string: "pensieve://unknown")!) == nil)         // unknown host
  #expect(DeepLink(url: URL(string: "pensieve://node")!) == nil)            // missing uuid
  #expect(DeepLink(url: URL(string: "pensieve://node/not-a-uuid")!) == nil) // bad uuid
  #expect(DeepLink(url: URL(string: "pensieve://smartlist/nope")!) == nil)  // unknown token
  #expect(DeepLink(url: URL(string: "pensieve://briefing/extra")!) == nil)  // trailing path
}

@Test func deepLinkSmartListTokensAreStable() {
  // MUST match the app's SmartListKind raw values.
  #expect(DeepLink.SmartList.whatsNext.rawValue == "whatsNext")
  #expect(DeepLink.SmartList.dormant.rawValue == "dormant")
  #expect(DeepLink.SmartList.recentlyActive.rawValue == "recentlyActive")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter DeepLink`
Expected: FAIL — `cannot find 'DeepLink' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PensieveKit/Support/DeepLink.swift`:

```swift
import Foundation

/// A `pensieve://` deep link — the foundational cross-surface entry point. Pure URL
/// parsing/serialization with no store access, so it is fully unit-tested. The menu-bar item is the
/// first consumer; later surfaces (widgets, Spotlight) reuse the same scheme.
///
/// Grammar: `pensieve://<host>[/<segment>]`
///   pensieve://briefing
///   pensieve://node/<uuid>
///   pensieve://smartlist/<whatsNext|dormant|recentlyActive>
public enum DeepLink: Equatable, Sendable {
  /// The three sidebar smart lists. Raw values match the app's `SmartListKind` raw values so the
  /// app-side bridge needs no hand-maintained string table.
  public enum SmartList: String, Equatable, Sendable {
    case whatsNext, dormant, recentlyActive
  }

  case briefing
  case node(UUID)
  case smartList(SmartList)

  public static let scheme = "pensieve"

  /// Parses a `pensieve://…` URL. Returns nil for any unknown/malformed form.
  public init?(url: URL) {
    guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
          comps.scheme == Self.scheme, let host = comps.host else { return nil }
    let segments = comps.path.split(separator: "/").map(String.init)
    switch host {
    case "briefing":
      guard segments.isEmpty else { return nil }
      self = .briefing
    case "node":
      guard segments.count == 1, let id = UUID(uuidString: segments[0]) else { return nil }
      self = .node(id)
    case "smartlist":
      guard segments.count == 1, let kind = SmartList(rawValue: segments[0]) else { return nil }
      self = .smartList(kind)
    default:
      return nil
    }
  }

  /// The canonical URL for this link. `DeepLink(url: link.url) == link` for every case.
  public var url: URL {
    var comps = URLComponents()
    comps.scheme = Self.scheme
    switch self {
    case .briefing:
      comps.host = "briefing"
    case .node(let id):
      comps.host = "node"
      comps.path = "/\(id.uuidString)"
    case .smartList(let kind):
      comps.host = "smartlist"
      comps.path = "/\(kind.rawValue)"
    }
    return comps.url!
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter DeepLink`
Expected: PASS (all 6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Support/DeepLink.swift Tests/PensieveKitTests/DeepLinkTests.swift
git commit -m "feat: pensieve:// DeepLink router (parse/serialize, tested)"
```

---

### Task 2: Register the `pensieve://` scheme via an XcodeGen-managed Info.plist

**Files:**
- Modify: `project.yml` (the `Pensieve` target)
- Modify: `.gitignore`
- Generated (gitignored): `Sources/PensieveApp/Info.plist`

**Interfaces:**
- Consumes: nothing.
- Produces: the built bundle's `Contents/Info.plist` now contains `CFBundleURLTypes` for scheme `pensieve`, while preserving `CFBundleName`, `CFBundleShortVersionString`, `CFBundleIconName`, `LSMinimumSystemVersion`.

**Why the care:** switching off `GENERATE_INFOPLIST_FILE` drops keys Xcode synthesizes from build settings (version, icon, name). We re-declare them explicitly and verify by diffing the built plist before/after.

- [ ] **Step 1: Baseline the current built Info.plist (pre-change)**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve \
  -configuration Debug -derivedDataPath ./.build-xcode build
PLIST=./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Info.plist
for k in CFBundleName CFBundleShortVersionString CFBundleIconName LSMinimumSystemVersion; do
  printf '%s = ' "$k"; /usr/libexec/PlistBuddy -c "Print :$k" "$PLIST" 2>/dev/null || echo "(absent)"
done
```
Expected (record these): `CFBundleName = Pensieve`, `CFBundleShortVersionString = 0.2`, `CFBundleIconName = Pensieve`, `LSMinimumSystemVersion = 14.0`. (`CFBundleURLTypes` is absent — that's what we add.)

- [ ] **Step 2: Edit `project.yml` — replace the `Pensieve` target's plist handling**

Replace the current target block:

```yaml
  Pensieve:
    type: application
    platform: macOS
    sources:
      - Sources/PensieveApp
      - icons/Pensieve.icon
    dependencies:
      - package: PensieveKit
        product: PensieveKit
    settings:
      base:
        PRODUCT_NAME: Pensieve
        PRODUCT_BUNDLE_IDENTIFIER: me.mazetti.pensieve
        ASSETCATALOG_COMPILER_APPICON_NAME: Pensieve
        GENERATE_INFOPLIST_FILE: "YES"
        MARKETING_VERSION: "0.2"
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_ALLOWED: "YES"
        CODE_SIGNING_REQUIRED: "NO"
```

with (note: `GENERATE_INFOPLIST_FILE` removed; `info:` block added):

```yaml
  Pensieve:
    type: application
    platform: macOS
    sources:
      - Sources/PensieveApp
      - icons/Pensieve.icon
    dependencies:
      - package: PensieveKit
        product: PensieveKit
    info:
      path: Sources/PensieveApp/Info.plist
      properties:
        CFBundleName: Pensieve
        CFBundleShortVersionString: "$(MARKETING_VERSION)"
        CFBundleVersion: "1"
        CFBundleIconName: Pensieve
        LSMinimumSystemVersion: "$(MACOSX_DEPLOYMENT_TARGET)"
        CFBundleURLTypes:
          - CFBundleURLName: me.mazetti.pensieve
            CFBundleURLSchemes:
              - pensieve
    settings:
      base:
        PRODUCT_NAME: Pensieve
        PRODUCT_BUNDLE_IDENTIFIER: me.mazetti.pensieve
        ASSETCATALOG_COMPILER_APPICON_NAME: Pensieve
        MARKETING_VERSION: "0.2"
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_ALLOWED: "YES"
        CODE_SIGNING_REQUIRED: "NO"
```

- [ ] **Step 3: Gitignore the XcodeGen-generated Info.plist**

Add to `.gitignore` (under the existing "Xcode (generated by XcodeGen…)" block, after `.build-xcode/`):

```
Sources/PensieveApp/Info.plist
```

- [ ] **Step 4: Regenerate + build**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve \
  -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Verify the plist — new key present AND baseline keys preserved**

Run:
```bash
PLIST=./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" "$PLIST"
for k in CFBundleName CFBundleShortVersionString CFBundleIconName LSMinimumSystemVersion; do
  printf '%s = ' "$k"; /usr/libexec/PlistBuddy -c "Print :$k" "$PLIST"
done
```
Expected: `CFBundleURLTypes` prints an array containing `CFBundleURLSchemes = (pensieve)`; and `CFBundleName = Pensieve`, `CFBundleShortVersionString = 0.2`, `CFBundleIconName = Pensieve`, `LSMinimumSystemVersion = 14.0` (all unchanged from the Step 1 baseline). If any regressed, fix the `info: properties` before continuing.

- [ ] **Step 6: Confirm the full suite is unaffected**

Run: `./scripts/test.sh`
Expected: all existing tests pass (138 + the 6 DeepLink tests from Task 1).

- [ ] **Step 7: Commit**

```bash
git add project.yml .gitignore
git commit -m "build: register pensieve:// URL scheme via XcodeGen-managed Info.plist"
```

---

### Task 3: Menu-bar scene + read-only popover glance

**Files:**
- Create: `Sources/PensieveApp/MenuBarView.swift`
- Modify: `Sources/PensieveApp/PensieveApp.swift`

**Interfaces:**
- Consumes: `AppModel` (`.snapshot: MonitorSnapshot`, `.lists: SmartLists`, `.start()`, `.refresh()`, `.refreshNow()`); `MonitorSnapshot.Status`; `SmartLists.whatsNext: [NextItem]` (`NextItem.project.name`, `.openLooseEnds`, `.daysDormant`).
- Produces: `struct MenuBarView: View`; `extension MonitorSnapshot.Status { var glyph: String; var label: String }` (app-side UI mapping). A `MenuBarExtra` scene in `PensieveApp`.

This task delivers the read-only glance. Click-to-jump navigation is added in Task 4.

- [ ] **Step 1: Create `MenuBarView.swift`**

```swift
// Sources/PensieveApp/MenuBarView.swift
import SwiftUI
import PensieveKit

/// App-side UI mapping for the heartbeat status (kept out of PensieveKit — SF Symbol names and
/// display words are UI concerns, like SmartListKind's title/symbol).
extension MonitorSnapshot.Status {
  var glyph: String {
    switch self {
    case .active: return "circle.fill"
    case .idle: return "circle"
    case .notSetUp: return "circle.slash"
    }
  }
  var label: String {
    switch self {
    case .active: return "Active"
    case .idle: return "Idle"
    case .notSetUp: return "Not set up"
    }
  }
}

/// The menu-bar popover content: capture heartbeat + a short What's Next glance. Reads the shared
/// AppModel and renders only — all data is from the tested MonitorSnapshot / SmartLists kernels.
struct MenuBarView: View {
  @ObservedObject var model: AppModel

  private static let maxRows = 5

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      heartbeat
      Divider()
      Text("What's Next").font(.caption).foregroundStyle(.secondary)
      whatsNext
      Divider()
      footer
    }
    .padding(12)
    .frame(width: 300)
    .task { model.refresh() }   // fresh on open (the 3 s Timer is suppressed while the menu is up)
  }

  @ViewBuilder private var heartbeat: some View {
    HStack(spacing: 6) {
      Image(systemName: model.snapshot.status.glyph)
      Text(statusLine).font(.callout).fontWeight(.medium)
      Spacer()
      Text("\(model.snapshot.looseEndCount) open").font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var whatsNext: some View {
    let items = Array(model.lists.whatsNext.prefix(Self.maxRows))
    if items.isEmpty {
      Text("Nothing queued").font(.callout).foregroundStyle(.secondary)
    } else {
      ForEach(items, id: \.project.id) { item in
        HStack {
          Text(item.project.name).lineLimit(1)
          Spacer()
          Text("\(item.openLooseEnds) open · \(item.daysDormant)d dormant")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder private var footer: some View {
    HStack {
      Button("Refresh") { Task { await model.refreshNow() } }
      Spacer()
      Button("Quit") { NSApplication.shared.terminate(nil) }
    }
  }

  private var statusLine: String {
    var s = model.snapshot.status.label
    if let last = model.snapshot.lastCaptureAt {
      s += " · captured \(Self.relativeAge(last))"
    }
    return s
  }

  /// Local formatter instance (no shared mutable static — Swift 6 concurrency rule).
  private static func relativeAge(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
  }
}
```

- [ ] **Step 2: Add the `MenuBarExtra` scene to `PensieveApp.swift`**

In `Sources/PensieveApp/PensieveApp.swift`, inside `var body: some Scene`, add a second scene immediately **after** the closing of the `Window { … }` scene's modifiers (after the `.commands { … }` block) and before the closing brace of `body`:

```swift
    MenuBarExtra {
      MenuBarView(model: model)
    } label: {
      Image(systemName: model.snapshot.status.glyph)
    }
    .menuBarExtraStyle(.window)
```

(The existing `Window(…) { … }.defaultSize(…).windowResizability(…).commands { … }` block is unchanged and stays first.)

- [ ] **Step 3: Build**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve \
  -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Smoke-launch (non-blocking) + manual visual check**

Run:
```bash
PENSIEVE_DB=/tmp/mb-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/mb-smoke-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
APP_PID=$!; sleep 3
kill $APP_PID 2>/dev/null; wait $APP_PID 2>/dev/null; echo "launched + exited cleanly"
```
Expected: prints `launched + exited cleanly` (no crash). **Manual (human) check** in a real run: a circle glyph appears in the menu bar; clicking it opens a ~300pt popover showing the heartbeat line, a "What's Next" section (or "Nothing queued"), and Refresh/Quit buttons. With a throwaway store the status reads "Not set up" (`circle.slash`).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveApp/MenuBarView.swift Sources/PensieveApp/PensieveApp.swift
git commit -m "feat: menu-bar popover with capture heartbeat + What's Next glance"
```

---

### Task 4: Deep-link navigation — in-process jump-in + external `pensieve://` opens

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift` (add `pendingDeepLink`)
- Create: `Sources/PensieveApp/DeepLinkNavigation.swift` (adapter + `applyDeepLink`)
- Create: `Sources/PensieveApp/AppDelegate.swift`
- Modify: `Sources/PensieveApp/MenuBarView.swift` (add `MenuBarLabel`; make rows/footer navigate)
- Modify: `Sources/PensieveApp/PensieveApp.swift` (adaptor + use `MenuBarLabel`)

**Interfaces:**
- Consumes: `DeepLink` (Task 1); `PaletteDestination` (`AppModel.swift`, cases `.briefing`, `.node(UUID)`, `.smartList(SmartListKind)`) and its `.apply(to: AppModel)`; `SmartListKind` (cases `.whatsNext`, `.dormant`, `.recentlyActive`); `AppModel.start()`.
- Produces: `AppModel.pendingDeepLink: DeepLink?`; `extension PaletteDestination { init(_ link: DeepLink) }`; `@MainActor func applyDeepLink(_:model:openWindow:)`; `final class AppDelegate`; `struct MenuBarLabel: View`.

- [ ] **Step 1: Add `pendingDeepLink` to `AppModel`**

In `Sources/PensieveApp/AppModel.swift`, add a published property to `AppModel` (next to the other `@Published` properties, e.g. after `@Published var showPalette = false`):

```swift
  /// Set by the AppDelegate when an external `pensieve://` URL is opened; observed by the
  /// always-mounted menu-bar label, which applies it and clears it back to nil.
  @Published var pendingDeepLink: DeepLink?
```

(`import PensieveKit` is already present at the top of the file.)

- [ ] **Step 2: Create `DeepLinkNavigation.swift` — the adapter + apply helper**

```swift
// Sources/PensieveApp/DeepLinkNavigation.swift
import SwiftUI
import AppKit
import PensieveKit

extension PaletteDestination {
  /// Maps a cross-surface DeepLink to the app's navigation destination. Exhaustive on both enums so
  /// a future smart list fails to compile here (no silent drift).
  init(_ link: DeepLink) {
    switch link {
    case .briefing:
      self = .briefing
    case .node(let id):
      self = .node(id)
    case .smartList(let s):
      switch s {
      case .whatsNext: self = .smartList(.whatsNext)
      case .dormant: self = .smartList(.dormant)
      case .recentlyActive: self = .smartList(.recentlyActive)
      }
    }
  }
}

/// The single navigation entry point for both internal menu-bar clicks and external `pensieve://`
/// opens: bring up the main window, front the app, and apply the destination via the existing ⌘K
/// path (`PaletteDestination.apply`, which sets both sidebarSelection and selectedNodeID).
@MainActor
func applyDeepLink(_ link: DeepLink, model: AppModel, openWindow: OpenWindowAction) {
  let dest = PaletteDestination(link)
  openWindow(id: "main")
  NSApplication.shared.activate()   // macOS 14 cooperative form (not ignoringOtherApps:)
  dest.apply(to: model)
}
```

- [ ] **Step 3: Create `AppDelegate.swift` — the scene-independent external-URL entry point**

```swift
// Sources/PensieveApp/AppDelegate.swift
import AppKit
import PensieveKit

/// Receives external `pensieve://` opens. This is a scene-independent entry point that fires
/// regardless of whether the main window is open (a menu-bar app commonly runs with no window), so
/// it does not depend on any SwiftUI view being mounted. It parses each URL to a DeepLink and hands
/// it to the shared AppModel; if the model isn't wired yet (app launched *by* the URL), it buffers
/// and flushes once the model is set.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel? {
    didSet { flush() }
  }
  private var buffered: [DeepLink] = []

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      guard let link = DeepLink(url: url) else { continue }
      if let model {
        model.pendingDeepLink = link
      } else {
        buffered.append(link)
      }
    }
  }

  private func flush() {
    guard let model, let last = buffered.last else { return }
    model.pendingDeepLink = last   // most recent wins; earlier buffered links are superseded
    buffered.removeAll()
  }
}
```

- [ ] **Step 4: Add `MenuBarLabel` to `MenuBarView.swift`**

Append to `Sources/PensieveApp/MenuBarView.swift`:

```swift
/// The always-mounted menu-bar label. Being always present, it is the reliable host for: wiring the
/// AppDelegate to the shared model, ensuring `start()` has run (so What's Next isn't empty even if
/// the main window never opened), and observing external deep links.
struct MenuBarLabel: View {
  @ObservedObject var model: AppModel
  let appDelegate: AppDelegate
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Image(systemName: model.snapshot.status.glyph)
      .task {
        appDelegate.model = model   // flushes any URL that arrived before the model was wired
        model.start()               // idempotent (guarded in AppModel)
      }
      .onChange(of: model.pendingDeepLink) { _, link in
        guard let link else { return }
        applyDeepLink(link, model: model, openWindow: openWindow)
        model.pendingDeepLink = nil
      }
  }
}
```

- [ ] **Step 5: Make the popover rows and footer navigate (`MenuBarView.swift`)**

In `MenuBarView`, add the environment action at the top of the struct (below `@ObservedObject var model`):

```swift
  @Environment(\.openWindow) private var openWindow
```

Replace the `whatsNext` computed view's `ForEach` row (the `HStack { … }`) with a `Button` that jumps in:

```swift
      ForEach(items, id: \.project.id) { item in
        Button {
          applyDeepLink(.node(item.project.id), model: model, openWindow: openWindow)
        } label: {
          HStack {
            Text(item.project.name).lineLimit(1)
            Spacer()
            Text("\(item.openLooseEnds) open · \(item.daysDormant)d dormant")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.plain)
      }
```

Replace the `footer` computed view to add "Open Pensieve" (routes through the briefing deep link):

```swift
  @ViewBuilder private var footer: some View {
    HStack {
      Button("Open Pensieve") {
        applyDeepLink(.briefing, model: model, openWindow: openWindow)
      }
      Spacer()
      Button("Refresh") { Task { await model.refreshNow() } }
      Button("Quit") { NSApplication.shared.terminate(nil) }
    }
  }
```

- [ ] **Step 6: Wire the adaptor + `MenuBarLabel` in `PensieveApp.swift`**

Add the delegate adaptor property to `PensieveApp` (next to `@StateObject private var model`):

```swift
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
```

Replace the `MenuBarExtra` label (the plain `Image(systemName:)` added in Task 3) with `MenuBarLabel`:

```swift
    MenuBarExtra {
      MenuBarView(model: model)
    } label: {
      MenuBarLabel(model: model, appDelegate: appDelegate)
    }
    .menuBarExtraStyle(.window)
```

- [ ] **Step 7: Build**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve \
  -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Smoke — internal jump-in (non-blocking launch)**

Run:
```bash
PENSIEVE_DB=/tmp/mb-smoke.sqlite PENSIEVE_CAPTURE_DB=/tmp/mb-smoke-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve &
APP_PID=$!; sleep 3
kill $APP_PID 2>/dev/null; wait $APP_PID 2>/dev/null; echo "launched + exited cleanly"
```
Expected: `launched + exited cleanly`. **Manual check** in a real run: open the popover, click a What's Next row → the main window comes to front and shows that node; click "Open Pensieve" → the window fronts on the Briefing.

- [ ] **Step 9: Smoke — external open with the window closed (proves the C1 fix)**

Register the built bundle so Launch Services resolves `pensieve://` to *this* copy, then test with the window closed. Run against the real app (not throwaway env, so the node id exists), or substitute a known id:
```bash
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREGISTER" -f ./.build-xcode/Build/Products/Debug/Pensieve.app
"$LSREGISTER" -dump | grep -i "pensieve.app" | head        # confirm this path is the handler
open ./.build-xcode/Build/Products/Debug/Pensieve.app       # launch it
# In the running app: close the main window (⌘W). Then:
open "pensieve://briefing"
```
Expected (manual): the main window **reopens and shows the Briefing** even though it was closed. If it does not fire, add a temporary `print("applyDeepLink \(link)")` in `applyDeepLink` and confirm it logs in the running process (Console.app / stderr). Quit the test app when done.

- [ ] **Step 10: Full suite stays green**

Run: `./scripts/test.sh`
Expected: all tests pass (138 + 6 DeepLink).

- [ ] **Step 11: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/DeepLinkNavigation.swift \
  Sources/PensieveApp/AppDelegate.swift Sources/PensieveApp/MenuBarView.swift \
  Sources/PensieveApp/PensieveApp.swift
git commit -m "feat: deep-link navigation for menu bar (in-process jump-in + external pensieve:// opens)"
```

---

## Post-implementation (whole-branch review + finish)

- Whole-branch Opus review (per `superpowers:subagent-driven-development`), fix waves, then `superpowers:finishing-a-development-branch` (user chooses "merge to main locally"; remove worktree + delete branch).
- On merge, record the deferred items in `docs/superpowers/backlog.md`: `LSUIElement`/hide-dock toggle (needs a Settings surface), menu-bar icon count badge, Dormant/Recently-Active peek in the popover, and note the `pensieve://` scheme is now live for future external consumers (widgets/Spotlight/notifications).
- No `~/.local/bin/pensieve` rebuild needed — this touches only the `PensieveApp` target + `project.yml`/`.gitignore`, not the CLI/daemon.

## Self-review notes (checked against the spec)

- **Spec coverage:** MenuBarExtra `.window` popover (T3), heartbeat line + top-5 What's Next + empty state (T3), status-by-glyph (T3), refresh-on-open + `start()` liveness (T3 popover + T4 label), `DeepLink` router tested (T1), scheme registration with preserved plist keys (T2), in-process internal nav + `AppDelegate` external path + `pendingDeepLink` + `PaletteDestination.apply` reuse (T4), `NSApplication.activate()` cooperative form (T4). All present.
- **Type consistency:** `DeepLink` / `DeepLink.SmartList` (T1) consumed by `PaletteDestination(_:)` (T4); `applyDeepLink(_:model:openWindow:)` defined T4-Step2, used T4-Steps 4–5; `MonitorSnapshot.Status.glyph/label` defined T3, reused by `MenuBarLabel` T4. `pendingDeepLink` defined T4-Step1, used T4-Steps 3–4.
- **No placeholders:** every code step is complete; smoke `open pensieve://` steps are concrete with `lsregister`.
