# App UI Verification Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the app target its first automated verification signal — a fast accessibility-based probe for driving the live app, and a deterministic XCUITest suite over a seeded fixture store — packaged as a repo skill so future sessions reach for them.

**Architecture:** Four independent pieces. A `swiftc`-built command-line tool at `Tools/uiprobe/` reads and drives the running app through `AXUIElement` (no build-system coupling to the app). A `bundle.ui-testing` target launches a *second* app instance against a temp store seeded by a new tested PensieveKit fixture. `make uitest` runs the suite outside `make all`. A `.claude/skills/verify-app-ui/` skill encodes when to use which.

**Tech Stack:** Swift 6, ApplicationServices (`AXUIElement`), CoreGraphics (`CGWindowList`, `CGEvent`), XCTest/XCUITest, XcodeGen, GNU make, SQLiteData/GRDB.

**Spec:** `docs/superpowers/specs/2026-08-13-app-ui-verification-harness-design.md`

## Global Constraints

- **No production code changes.** The only `Sources/` addition is the fixture seeder + its test. If a task seems to need an app or Kit behaviour change, stop and raise it.
- **The live app is read-and-navigate only.** Anything that writes (rename, merge, archive, resolve, new node) goes through the XCUITest suite against a fixture store. Never drive write paths against `~/Library/Application Support/Pensieve/`.
- **Naming:** explicit, no abbreviations (`database`/`node`/`element`, never `db`/`n`/`el`). SwiftLint `identifier_name` min 3, max 50; `line_length` warning 140.
- **SQLiteData predicates use `.eq(x)`, never `== x`.**
- **No Python.** Swift and shell only.
- **Tests:** `make test [FILTER=<name>]`. Swift Testing (`@Test`, `#expect`), not XCTest — *except* in `Tests/PensieveUITests`, which must be XCTest because XCUITest requires it.
- **Commit after every task.** Message bodies wrap at 72 columns; never put backticks inside `git commit -m "…"` (they shell-execute) — use `-F -` with a heredoc.
- `make` targets are the canonical interface; raw `xcodebuild`/`swift` only when debugging a recipe.

---

### Task 1: `uiprobe` — accessibility core, `windows` and `dump`

**Files:**
- Create: `Tools/uiprobe/AccessibilityElement.swift`
- Create: `Tools/uiprobe/WindowList.swift`
- Create: `Tools/uiprobe/main.swift`
- Modify: `Makefile` (add `uiprobe` target, extend `SWIFT_SOURCES`, add to `.PHONY`)
- Modify: `.swiftlint.yml` (add `Tools` to `included`)

No `.gitignore` change: the binary goes to `.build/`, already ignored, and `make clean` already
does `rm -rf .build`, so it is covered by both.

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct AccessibilityElement` wrapping `AXUIElement`, with `init(element:)`, `init(application: pid_t)`, `var role: String`, `var identifier: String?`, `var isSelected: Bool`, `var children: [AccessibilityElement]`, `var parent: AccessibilityElement?`, `var windows: [AccessibilityElement]`, `var frame: CGRect?`, `var primaryText: String?`, `func text(_ attribute: String) -> String?`, `var descriptionLine: String`
  - `func nearestAncestor(of element: AccessibilityElement, role wanted: String) -> AccessibilityElement?`
  - `func firstDescendant(of element: AccessibilityElement, matchingText needle: String) -> AccessibilityElement?`
  - `struct PensieveWindow { let processIdentifier: pid_t; let windowIdentifier: CGWindowID; let title: String; let bounds: CGRect }` and `func pensieveWindows() -> [PensieveWindow]`
  - CLI: `uiprobe windows`, `uiprobe dump [--pid N] [--depth N] [--grep PATTERN]`

**Context an implementer needs:**

The probe must never be placed under `Sources/`. The Makefile's `BUILD_SOURCES` globs all of `Sources/`, so a probe there would invalidate the app build record on every probe edit (~35 s rebuild to tweak a debugging tool).

SwiftUI outline rows expose **no `AXPress` action** — this is measured, not assumed. Do not build the element model around actions.

macOS redacts `kCGWindowName` when Screen Recording is not granted. That is the detection signal for a missing TCC grant, so `pensieveWindows()` must surface an empty title rather than skipping the window.

- [ ] **Step 1: Write the accessibility element wrapper**

Create `Tools/uiprobe/AccessibilityElement.swift`:

```swift
import ApplicationServices
import Cocoa

/// A thin value wrapper over `AXUIElement`. Every accessor returns nil/empty rather than throwing:
/// a probe that dies on one unreadable attribute is useless against a live, changing UI.
struct AccessibilityElement {
  let element: AXUIElement

  init(element: AXUIElement) { self.element = element }

  init(application processIdentifier: pid_t) {
    self.element = AXUIElementCreateApplication(processIdentifier)
  }

  private func copyAttribute(_ attribute: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  func text(_ attribute: String) -> String? {
    guard let value = copyAttribute(attribute) as? String, !value.isEmpty else { return nil }
    return value
  }

  var role: String { text(kAXRoleAttribute) ?? "AXUnknown" }
  var identifier: String? { text(kAXIdentifierAttribute) }
  var isSelected: Bool { copyAttribute(kAXSelectedAttribute) as? Bool ?? false }

  var children: [AccessibilityElement] {
    (copyAttribute(kAXChildrenAttribute) as? [AXUIElement] ?? []).map(AccessibilityElement.init(element:))
  }

  var parent: AccessibilityElement? {
    guard let raw = copyAttribute(kAXParentAttribute) else { return nil }
    return AccessibilityElement(element: raw as! AXUIElement)
  }

  var windows: [AccessibilityElement] {
    (copyAttribute(kAXWindowsAttribute) as? [AXUIElement] ?? []).map(AccessibilityElement.init(element:))
  }

  var frame: CGRect? {
    guard let positionValue = copyAttribute(kAXPositionAttribute),
          let sizeValue = copyAttribute(kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
  }

  /// The best single label for this element, used for `find`/`select`/`click` matching.
  var primaryText: String? {
    text(kAXValueAttribute) ?? text(kAXTitleAttribute) ?? text(kAXDescriptionAttribute)
  }

  /// One line of `dump` output: role, then every non-empty text attribute, then flags.
  var descriptionLine: String {
    var parts = [role]
    for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
      if let value = text(attribute) {
        parts.append("\(attribute.dropFirst(2)): \u{201C}\(value)\u{201D}")
      }
    }
    if let identifier { parts.append("id: \(identifier)") }
    if isSelected { parts.append("SELECTED") }
    return parts.joined(separator: "  ")
  }
}

/// Depth-first search for the first element whose primary text equals `needle`.
/// Exact match, not substring: a substring match on a tree this size returns the wrong row often
/// enough to be worse than no match at all.
func firstDescendant(of root: AccessibilityElement,
                     matchingText needle: String,
                     depth: Int = 0) -> AccessibilityElement? {
  if depth > 40 { return nil }
  if root.primaryText == needle { return root }
  for child in root.children {
    if let hit = firstDescendant(of: child, matchingText: needle, depth: depth + 1) { return hit }
  }
  return nil
}

/// Walks up to the nearest ancestor with the given role. SwiftUI list selection is driven on the
/// `AXRow`, which is several levels above the `AXStaticText` a human would name.
func nearestAncestor(of element: AccessibilityElement, role wanted: String) -> AccessibilityElement? {
  var current: AccessibilityElement? = element
  for _ in 0..<10 {
    guard let candidate = current else { return nil }
    if candidate.role == wanted { return candidate }
    current = candidate.parent
  }
  return nil
}
```

- [ ] **Step 2: Write the window lister**

Create `Tools/uiprobe/WindowList.swift`:

```swift
import CoreGraphics
import Cocoa

let pensieveBundleIdentifier = "me.mazetti.pensieve"

struct PensieveWindow {
  let processIdentifier: pid_t
  let windowIdentifier: CGWindowID
  let title: String
  let bounds: CGRect
}

/// On-screen windows belonging to Pensieve processes.
///
/// An empty `title` is meaningful: macOS redacts `kCGWindowName` when Screen Recording is not
/// granted, so a window listed with no title is the signal that the grant is missing — which is why
/// such windows are returned rather than filtered out.
func pensieveWindows() -> [PensieveWindow] {
  let pensievePIDs = Set(
    NSRunningApplication.runningApplications(withBundleIdentifier: pensieveBundleIdentifier)
      .map(\.processIdentifier)
  )
  let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
  guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    return []
  }
  return raw.compactMap { entry in
    guard let processIdentifier = entry[kCGWindowOwnerPID as String] as? pid_t,
          pensievePIDs.contains(processIdentifier),
          let windowIdentifier = entry[kCGWindowNumber as String] as? CGWindowID else { return nil }
    var bounds = CGRect.zero
    if let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Any] {
      bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) ?? .zero
    }
    return PensieveWindow(
      processIdentifier: processIdentifier,
      windowIdentifier: windowIdentifier,
      title: entry[kCGWindowName as String] as? String ?? "",
      bounds: bounds
    )
  }
}

/// Resolves which Pensieve process to target. A fixture-backed instance and the live app share a
/// bundle identifier, so an ambiguous target is an error rather than a coin flip.
func resolveTargetProcess(explicit: pid_t?) -> Result<pid_t, String> {
  if let explicit { return .success(explicit) }
  let running = NSRunningApplication.runningApplications(withBundleIdentifier: pensieveBundleIdentifier)
  switch running.count {
  case 0: return .failure("Pensieve is not running")
  case 1: return .success(running[0].processIdentifier)
  default:
    let pids = running.map { String($0.processIdentifier) }.joined(separator: ", ")
    return .failure("\(running.count) Pensieve instances running (pids: \(pids)) — pass --pid")
  }
}
```

- [ ] **Step 3: Write the command dispatcher with `windows` and `dump`**

Create `Tools/uiprobe/main.swift`:

```swift
import Cocoa
import Foundation

func failWith(_ message: String) -> Never {
  FileHandle.standardError.write(Data(("uiprobe: " + message + "\n").utf8))
  exit(1)
}

func flagValue(_ name: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

let usage = """
usage: uiprobe <command> [options]

  windows                                  list Pensieve windows (pid, id, title, bounds)
  dump    [--pid N] [--depth N] [--grep P] print the accessibility tree
  find    <text> [--pid N]                 locate an element by exact label
  select  <text> [--pid N]                 select the nearest AXRow ancestor
  click   <text> [--pid N]                 synthetic click at the element's centre
  key     <chord> [--pid N]                send keys, e.g. cmd+f / escape / "some text"
  shot    [--pid N] [--out PATH]           capture the window to PNG

An empty window title in `windows` means Screen Recording is not granted.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { print(usage); exit(2) }

let explicitPID = flagValue("--pid", in: arguments).flatMap { pid_t($0) }

func targetPID() -> pid_t {
  switch resolveTargetProcess(explicit: explicitPID) {
  case .success(let pid): return pid
  case .failure(let message): failWith(message)
  }
}

func printTree(_ element: AccessibilityElement, depth: Int, maxDepth: Int, into lines: inout [String]) {
  lines.append(String(repeating: "  ", count: depth) + element.descriptionLine)
  guard depth < maxDepth else { return }
  for child in element.children {
    printTree(child, depth: depth + 1, maxDepth: maxDepth, into: &lines)
  }
}

switch command {
case "windows":
  let windows = pensieveWindows()
  if windows.isEmpty { failWith("no Pensieve windows on screen") }
  for window in windows {
    let title = window.title.isEmpty ? "<no title — Screen Recording not granted>" : window.title
    print("pid=\(window.processIdentifier) window=\(window.windowIdentifier) "
          + "title=\u{201C}\(title)\u{201D} bounds=\(window.bounds.debugDescription)")
  }

case "dump":
  let maxDepth = flagValue("--depth", in: arguments).flatMap { Int($0) } ?? 16
  let application = AccessibilityElement(application: targetPID())
  let windows = application.windows
  if windows.isEmpty { failWith("no accessible windows — is Accessibility granted?") }
  var lines: [String] = []
  for window in windows { printTree(window, depth: 0, maxDepth: maxDepth, into: &lines) }
  if let pattern = flagValue("--grep", in: arguments) {
    lines = lines.filter { $0.range(of: pattern, options: [.caseInsensitive, .regularExpression]) != nil }
    if lines.isEmpty { failWith("no line matched /\(pattern)/") }
  }
  print(lines.joined(separator: "\n"))

default:
  print(usage)
  exit(2)
}
```

- [ ] **Step 4: Add the `make uiprobe` rule and lint wiring**

In `Makefile`, add `uiprobe` to the `.PHONY` line, extend the lint input, and add the rule. `SWIFT_SOURCES` currently reads:

```make
SWIFT_SOURCES := $(shell find Sources Tests -type f -name '*.swift')
```

Change it to:

```make
SWIFT_SOURCES := $(shell find Sources Tests Tools -type f -name '*.swift')
```

Add near the `CLI` definition:

```make
# The UI probe: a development tool, deliberately outside Sources/ because BUILD_SOURCES globs that
# directory — a probe there would trigger a full app rebuild on every probe edit.
UIPROBE = ./.build/uiprobe
UIPROBE_SOURCES := $(shell find Tools/uiprobe -type f -name '*.swift')
```

Add the target and rule (put `uiprobe` in `.PHONY` and in the help block ordering next to `cli`):

```make
uiprobe: $(UIPROBE) ## Build the accessibility probe for driving the running app

$(UIPROBE): $(UIPROBE_SOURCES)
	@mkdir -p $(dir $@)
	@swiftc -O $(UIPROBE_SOURCES) -o $@
	@echo "ok: $@"
```

- [ ] **Step 5: Add `Tools` to the lint scope**

In `.swiftlint.yml`, the `included:` list scopes what SwiftLint actually reads. Extending `SWIFT_SOURCES` alone only invalidates the make record — it does not lint anything. Change:

```yaml
included:
  - Sources
  - Tests
```

to:

```yaml
included:
  - Sources
  - Tests
  - Tools
```

- [ ] **Step 6: Build and verify against the running app**

There are no unit tests for `uiprobe` — it is `AXUIElement` glue whose only meaningful assertion needs a live app, and a mock would test the mock. The spec records this as a deliberate exception. Verification is by use, with expected output:

```bash
make uiprobe
open -a Pensieve          # or `make run` if it is not installed yet
./.build/uiprobe windows
```

Expected: at least one line, `pid=… window=… title="Pensieve – N Projekte" bounds=…`.
If the title prints `<no title — Screen Recording not granted>`, stop and grant Screen Recording to the terminal before continuing — every later step depends on it.

```bash
./.build/uiprobe dump --depth 6 | head -20
```

Expected: a tree beginning `AXWindow  Title: "Pensieve – …"  id: main`, then `AXSplitGroup … id: main, SidebarNavigationSplitView`.

```bash
./.build/uiprobe dump --grep 'Briefing'
```

Expected: at least one line containing `AXStaticText  Value: "Briefing"`. Exit code 0.

```bash
./.build/uiprobe dump --grep 'ZZZ-not-present'; echo "exit=$?"
```

Expected: `uiprobe: no line matched /ZZZ-not-present/` on stderr and `exit=1` — a failed lookup must be distinguishable from an empty result.

- [ ] **Step 7: Verify lint and the build cache both behave**

```bash
make lint
```
Expected: passes, and now covers `Tools`. Verify coverage is real rather than assumed:

```bash
printf '\nlet xy = 1\n' >> Tools/uiprobe/WindowList.swift && make lint; echo "exit=$?"
```
Expected: **fails** on `identifier_name` (min length 3). This proves `Tools` is genuinely linted rather than silently skipped. Then revert:

```bash
git checkout Tools/uiprobe/WindowList.swift
```

```bash
make uiprobe && make uiprobe
```
Expected: the second run prints nothing (cached). Confirm the app build record was untouched by the new tool:

```bash
make build
```
Expected: no rebuild (already up to date from before this task).

- [ ] **Step 8: Commit**

```bash
git add Tools/uiprobe Makefile .swiftlint.yml
git commit -F - <<'EOF'
feat: add uiprobe, an accessibility probe for the running app

The app target has no automated signal, so verifying a UI change has meant
asking the user to click through it. This reads the live app's accessibility
tree as greppable text, which answers most of what the human-verify ledger
actually asks -- ordering, labels, counts, localization.

Lives in Tools/ rather than Sources/ because BUILD_SOURCES globs Sources,
so a probe there would trigger a full app rebuild on every probe edit.

Not unit-tested by design: it is AXUIElement glue whose only meaningful
assertion needs a live app, and a mock would test the mock.
EOF
```

---

### Task 2: `uiprobe` — `find`, `select`, `click`, `key`, `shot`

**Files:**
- Create: `Tools/uiprobe/Actions.swift`
- Modify: `Tools/uiprobe/main.swift` (add the five cases to the `switch`)

**Interfaces:**
- Consumes: `AccessibilityElement`, `firstDescendant(of:matchingText:)`, `nearestAncestor(of:role:)`, `pensieveWindows()`, `resolveTargetProcess(explicit:)`, `failWith(_:)`, `flagValue(_:in:)` from Task 1.
- Produces:
  - `func selectRow(containing element: AccessibilityElement) -> Bool`
  - `func clickCentre(of element: AccessibilityElement, activating application: NSRunningApplication?) -> Bool`
  - `func sendChord(_ chord: String) -> Bool`
  - `func captureWindow(_ window: PensieveWindow, to path: String) -> Bool`
  - CLI: `uiprobe find|select|click|key|shot`

**Context an implementer needs:**

SwiftUI outline rows expose no `AXPress`; selection works by setting `kAXSelectedAttribute` on the nearest `AXRow` ancestor. This was measured — the window title changed from `Pensieve – 182 Projekte` to `Pensieve – 0 abgeschlossen` when applied to the *Abgeschlossen* row.

`click` is the general fallback for anything that is not a row (buttons, toolbar items). It posts real `CGEvent`s, so the app must be frontmost first or the click lands on whatever is.

`shot` shells out to `/usr/sbin/screencapture -x -o -l <windowID>`; `-x` suppresses the shutter sound, `-o` omits the window shadow.

- [ ] **Step 1: Write the actions**

Create `Tools/uiprobe/Actions.swift`:

```swift
import ApplicationServices
import Cocoa

/// SwiftUI list rows expose no AXPress action — selection is driven by setting AXSelected on the
/// nearest AXRow ancestor. Measured, not assumed: an AXPress-based probe appears broken instead.
func selectRow(containing element: AccessibilityElement) -> Bool {
  guard let row = nearestAncestor(of: element, role: "AXRow") else { return false }
  return AXUIElementSetAttributeValue(row.element, kAXSelectedAttribute as CFString, true as CFTypeRef)
    == .success
}

/// Posts a real click at the element's centre. The general fallback for controls that are not rows.
func clickCentre(of element: AccessibilityElement, activating application: NSRunningApplication?) -> Bool {
  guard let frame = element.frame else { return false }
  let point = CGPoint(x: frame.midX, y: frame.midY)
  application?.activate()
  usleep(200_000)
  guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left),
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left) else { return false }
  down.post(tap: .cghidEventTap)
  usleep(60_000)
  up.post(tap: .cghidEventTap)
  return true
}

private let namedKeys: [String: CGKeyCode] = [
  "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
  "left": 123, "right": 124, "down": 125, "up": 126,
  "f": 3, "g": 4, "n": 45, "r": 15, "k": 40, "i": 34,
]

/// Sends a chord such as `cmd+f`, `shift+cmd+g`, or a bare named key such as `escape`.
/// Anything not recognised as a chord is typed as literal text.
func sendChord(_ chord: String) -> Bool {
  let parts = chord.lowercased().split(separator: "+").map(String.init)
  guard let last = parts.last else { return false }

  guard let keyCode = namedKeys[last] else {
    // Not a known key — type it as literal text.
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return false }
    let characters = Array(chord.utf16)
    event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
    event.post(tap: .cghidEventTap)
    return true
  }

  var flags = CGEventFlags()
  for modifier in parts.dropLast() {
    switch modifier {
    case "cmd", "command": flags.insert(.maskCommand)
    case "shift": flags.insert(.maskShift)
    case "opt", "option", "alt": flags.insert(.maskAlternate)
    case "ctrl", "control": flags.insert(.maskControl)
    default: return false
    }
  }
  guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return false }
  down.flags = flags
  up.flags = flags
  down.post(tap: .cghidEventTap)
  usleep(40_000)
  up.post(tap: .cghidEventTap)
  return true
}

func captureWindow(_ window: PensieveWindow, to path: String) -> Bool {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  process.arguments = ["-x", "-o", "-l", String(window.windowIdentifier), path]
  do { try process.run() } catch { return false }
  process.waitUntilExit()
  return process.terminationStatus == 0
}
```

- [ ] **Step 2: Wire the five commands into the dispatcher**

In `Tools/uiprobe/main.swift`, insert these cases before `default:`:

```swift
case "find", "select", "click":
  guard arguments.count > 1, !arguments[1].hasPrefix("--") else {
    failWith("\(command) needs a text argument")
  }
  let needle = arguments[1]
  let processIdentifier = targetPID()
  let application = AccessibilityElement(application: processIdentifier)
  guard let hit = firstDescendant(of: application, matchingText: needle) else {
    failWith("no element labelled \u{201C}\(needle)\u{201D}")
  }
  switch command {
  case "find":
    let frame = hit.frame.map(\.debugDescription) ?? "<no frame>"
    print("\(hit.descriptionLine)  frame=\(frame)")
  case "select":
    guard selectRow(containing: hit) else { failWith("no AXRow ancestor for \u{201C}\(needle)\u{201D}") }
    print("selected row for \u{201C}\(needle)\u{201D}")
  default:
    let running = NSRunningApplication(processIdentifier: processIdentifier)
    guard clickCentre(of: hit, activating: running) else { failWith("element has no frame to click") }
    print("clicked \u{201C}\(needle)\u{201D}")
  }

case "key":
  guard arguments.count > 1 else { failWith("key needs a chord, e.g. cmd+f") }
  NSRunningApplication(processIdentifier: targetPID())?.activate()
  usleep(200_000)
  guard sendChord(arguments[1]) else { failWith("could not parse chord \u{201C}\(arguments[1])\u{201D}") }
  print("sent \(arguments[1])")

case "shot":
  let processIdentifier = targetPID()
  guard let window = pensieveWindows().first(where: { $0.processIdentifier == processIdentifier }) else {
    failWith("no on-screen window for pid \(processIdentifier)")
  }
  let path = flagValue("--out", in: arguments) ?? "pensieve-window.png"
  guard captureWindow(window, to: path) else { failWith("screencapture failed") }
  print("wrote \(path)")
```

- [ ] **Step 3: Build**

```bash
make uiprobe
```
Expected: `ok: ./.build/uiprobe`.

- [ ] **Step 4: Verify each command against the live app**

These are navigation-only and safe against the real store. Run them in order and check the app on screen.

```bash
./.build/uiprobe find "Briefing"
```
Expected: `AXStaticText  Value: "Briefing"  frame=(…)`.

```bash
./.build/uiprobe select "Abgeschlossen" && sleep 1 && ./.build/uiprobe dump --depth 1
```
Expected: `selected row…`, then a window title containing `abgeschlossen` — proof the app navigated.

```bash
./.build/uiprobe select "Briefing"
```
Restores the app. **Do this — leaving the user's app on a different view is rude.**

```bash
./.build/uiprobe key cmd+f && sleep 1 && ./.build/uiprobe dump --grep 'AXTextField'
```
Expected: a find field appears in the tree. Then `./.build/uiprobe key escape` to dismiss it.

```bash
./.build/uiprobe shot --out /tmp/probe.png && ls -l /tmp/probe.png
```
Expected: a PNG of a few hundred KB.

```bash
./.build/uiprobe find "ZZZ-not-present"; echo "exit=$?"
```
Expected: stderr message and `exit=1`.

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add Tools/uiprobe
git commit -F - <<'EOF'
feat: give uiprobe find, select, click, key and shot

Selection sets AXSelected on the nearest AXRow ancestor rather than sending
AXPress: SwiftUI outline rows expose no press action, so an AXPress-based
probe looks broken instead of working. Synthetic CGEvent clicks remain the
general fallback for controls that are not rows.
EOF
```

---

### Task 3: The fixture seeder in PensieveKit

**Files:**
- Create: `Sources/PensieveKit/Support/UITestFixture.swift`
- Create: `Tests/PensieveKitTests/UITestFixtureTests.swift`

**Interfaces:**
- Consumes: `openCanonicalDatabase(at:)`, `Node`, `NodeKind`, `NodeState`, `Source`, `Event`, `LooseEnd`, `LooseEndStatus` (all existing PensieveKit types).
- Produces:
  - `public enum UITestFixture` with:
    - `public static func seed(canonicalAt url: URL, now: Date) throws`
    - `public enum ID` — fixed UUID constants: `workDomain`, `colibri`, `colibriStrand`, `dormantProject`, `archivedProject`, `personalProject`
    - `public static let colibriOpenLooseEndText: String`, `public static let colibriOpenLooseEndQuote: String`

**Context an implementer needs:**

This is the one place a mistake is invisible: a wrong fixture leaves every UI test above it green against the wrong world. Hence the unit test on the seeded shape.

Dates must be **offsets from an injected `now`**, never absolute, so relative labels ("vor 3 Stunden") and dormancy buckets stay stable across runs.

`LooseEnd.isOpen` is `status == .open AND label != "noise"`. A fixture loose end intended to be open must therefore leave `label` as `""`.

Existing test style is Swift Testing (`@Test`, `#expect`) with the `tempURL(_:)` helper from `Tests/PensieveKitTests/TestSupport.swift`. Insert rows with SQLiteData: `try database.write { db in try Node.insert { node }.execute(db) }` — match the spelling used in `Tests/PensieveKitTests/NodeCommandsTests.swift` and `CanonicalStoreTests.swift`; read those two files first and copy their insert idiom exactly rather than inventing one.

- [ ] **Step 1: Write the failing test**

Create `Tests/PensieveKitTests/UITestFixtureTests.swift`:

```swift
import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func fixtureSeedsTheShapeTheUITestsAssert() throws {
  let url = tempURL("uifixture")
  let now = Date(timeIntervalSince1970: 1_770_000_000)
  try UITestFixture.seed(canonicalAt: url, now: now)

  let database = try openCanonicalDatabase(at: url)

  let nodes = try database.read { db in try Node.all.fetchAll(db) }
  #expect(nodes.count == 6)

  // The tree the sidebar renders: Colibri nests under the Work domain, and the strand under Colibri.
  let colibri = try #require(nodes.first { $0.id == UITestFixture.ID.colibri })
  #expect(colibri.parentID == UITestFixture.ID.workDomain)
  let strand = try #require(nodes.first { $0.id == UITestFixture.ID.colibriStrand })
  #expect(strand.parentID == UITestFixture.ID.colibri)
  #expect(strand.kind == NodeKind.strand)

  // Exactly one archived node — the Archived sidebar section asserts on this count.
  #expect(nodes.filter { $0.state == NodeState.archived }.count == 1)

  // Focus filtering needs one node of each explicit context, and unset nodes to prove they always show.
  #expect(nodes.filter { $0.context == "work" }.count == 1)
  #expect(nodes.filter { $0.context == "personal" }.count == 1)

  // Open vs closed loose ends drive the sidebar counts and the collapsed "Done · N" record.
  let looseEnds = try database.read { db in try LooseEnd.all.fetchAll(db) }
  let open = looseEnds.filter { $0.status == LooseEndStatus.open && $0.label != "noise" }
  #expect(open.count == 3)
  #expect(looseEnds.filter { $0.status == LooseEndStatus.done }.count == 1)

  // The quote is what the provenance row renders verbatim; the UI test greps for it.
  #expect(open.contains { $0.quote == UITestFixture.colibriOpenLooseEndQuote })

  // Dates are offsets from the injected now, so relative labels are stable across runs.
  let events = try database.read { db in try Event.all.fetchAll(db) }
  #expect(events.allSatisfy { $0.occurredAt <= now })
  #expect(events.contains { now.timeIntervalSince($0.occurredAt) < 3 * 3600 })      // "recently active"
  #expect(events.contains { now.timeIntervalSince($0.occurredAt) > 30 * 86_400 })   // dormant
}
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
make test FILTER=fixtureSeedsTheShapeTheUITestsAssert
```
Expected: FAIL — `cannot find 'UITestFixture' in scope`.

- [ ] **Step 3: Write the seeder**

Create `Sources/PensieveKit/Support/UITestFixture.swift`. Fill in the insert idiom copied from `CanonicalStoreTests.swift`:

```swift
import Foundation
import SQLiteData

/// A small, deterministic world for the app's XCUITest suite to launch against.
///
/// It lives here rather than in the test target because a wrong fixture is invisible: the UI tests
/// above it stay green while asserting against the wrong world. `UITestFixtureTests` pins its shape.
///
/// Every date is an offset from an injected `now` so relative labels ("vor 3 Stunden") and dormancy
/// buckets are stable across runs. UUIDs are fixed so tests and `pensieve://` deep links can address
/// nodes directly.
public enum UITestFixture {
  public enum ID {
    public static let workDomain = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    public static let colibri = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    public static let colibriStrand = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
    public static let dormantProject = UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!
    public static let archivedProject = UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!
    public static let personalProject = UUID(uuidString: "00000000-0000-0000-0000-0000000000A6")!
  }

  public static let colibriOpenLooseEndText = "Decide whether the parser keeps the retry shim"
  public static let colibriOpenLooseEndQuote =
    "we should probably decide whether the parser keeps the retry shim before shipping"

  public static func seed(canonicalAt url: URL, now: Date) throws {
    let database = try openCanonicalDatabase(at: url)

    let nodes = [
      Node(id: ID.workDomain, name: "Work", state: .active, createdAt: now.addingTimeInterval(-90 * 86_400),
           parentID: nil, kind: .domain, description: "Everything paid for", context: "work"),
      Node(id: ID.colibri, name: "Colibri", state: .active, createdAt: now.addingTimeInterval(-60 * 86_400),
           parentID: ID.workDomain, kind: .project, description: "Hummingbird ingest pipeline"),
      Node(id: ID.colibriStrand, name: "retry-shim", state: .active,
           createdAt: now.addingTimeInterval(-5 * 86_400), parentID: ID.colibri, kind: .strand,
           description: "", branchKey: "retry-shim"),
      Node(id: ID.dormantProject, name: "Countries List", state: .active,
           createdAt: now.addingTimeInterval(-120 * 86_400), parentID: nil, kind: .project,
           description: "Static reference data"),
      Node(id: ID.archivedProject, name: "Old Prototype", state: .archived,
           createdAt: now.addingTimeInterval(-200 * 86_400), parentID: nil, kind: .project,
           description: "Superseded"),
      Node(id: ID.personalProject, name: "Sourdough Log", state: .active,
           createdAt: now.addingTimeInterval(-30 * 86_400), parentID: nil, kind: .project,
           description: "Weekend baking", context: "personal"),
    ]

    let colibriSource = Source(nodeID: ID.colibri, kind: "gitRepo", key: "/tmp/fixture/colibri")
    let dormantSource = Source(nodeID: ID.dormantProject, kind: "gitRepo", key: "/tmp/fixture/countries")

    let recentSession = Event(
      nodeID: ID.colibri, sourceID: colibriSource.id, occurredAt: now.addingTimeInterval(-2 * 3600),
      kind: "cc.session", summary: "session (5 prompts)", detailJSON: #"{"files":["Sources/Parser.swift"]}"#
    )
    let recentCommit = Event(
      nodeID: ID.colibriStrand, sourceID: colibriSource.id, occurredAt: now.addingTimeInterval(-3 * 86_400),
      kind: "git.commit", summary: "fix: drop the retry shim's dead branch",
      detailJSON: #"{"files":["Sources/Parser.swift"]}"#
    )
    let dormantCommit = Event(
      nodeID: ID.dormantProject, sourceID: dormantSource.id,
      occurredAt: now.addingTimeInterval(-40 * 86_400),
      kind: "git.commit", summary: "chore: refresh ISO codes", detailJSON: #"{"files":["data/iso.json"]}"#
    )

    let looseEnds = [
      LooseEnd(nodeID: ID.colibri, sourceEventID: recentSession.id,
               text: colibriOpenLooseEndText, quote: colibriOpenLooseEndQuote,
               status: .open, role: "user", sourceMessageIndex: 4),
      LooseEnd(nodeID: ID.colibri, sourceEventID: recentSession.id,
               text: "Check the ingest watermark after the shim change",
               quote: "and check the ingest watermark after that change lands",
               status: .open, role: "user", sourceMessageIndex: 9),
      LooseEnd(nodeID: ID.dormantProject, sourceEventID: dormantCommit.id,
               text: "Verify the ISO refresh against the upstream list",
               quote: "verify the ISO refresh against the upstream list at some point",
               status: .open, role: "user", sourceMessageIndex: 2),
      LooseEnd(nodeID: ID.colibri, sourceEventID: recentSession.id,
               text: "Rename the parser fixture directory",
               quote: "we should rename that parser fixture directory",
               status: .done, role: "user", sourceMessageIndex: 12,
               resolvedAt: now.addingTimeInterval(-6 * 3600)),
    ]

    try database.write { db in
      for node in nodes { try Node.insert { node }.execute(db) }
      for source in [colibriSource, dormantSource] { try Source.insert { source }.execute(db) }
      for event in [recentSession, recentCommit, dormantCommit] { try Event.insert { event }.execute(db) }
      for looseEnd in looseEnds { try LooseEnd.insert { looseEnd }.execute(db) }
    }
  }
}
```

- [ ] **Step 4: Run the test until it passes**

```bash
make test FILTER=fixtureSeedsTheShapeTheUITestsAssert
```
Expected: PASS. If the insert spelling is wrong it will fail to compile — read `CanonicalStoreTests.swift` and match its idiom exactly.

- [ ] **Step 5: Run the whole suite and lint**

```bash
make test && make lint
```
Expected: the full suite green (754 tests + 1 new = 755), lint clean. (Baseline reconciled 2026-08-15: the plan was written at 681.)

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Support/UITestFixture.swift Tests/PensieveKitTests/UITestFixtureTests.swift
git commit -F - <<'EOF'
feat: add a deterministic fixture store for the UI test suite

Lives in PensieveKit with its own test rather than in the UI test target,
because a wrong fixture is invisible: every UI test above it stays green
while asserting against the wrong world.

Dates are offsets from an injected now, so relative labels and dormancy
buckets stay stable across runs; UUIDs are fixed so tests and deep links
can address nodes directly.
EOF
```

---

### Task 4: The `PensieveUITests` target, first test, and `make uitest`

**Files:**
- Create: `Tests/PensieveUITests/AppLaunch.swift`
- Create: `Tests/PensieveUITests/LaunchSmokeTests.swift`
- Modify: `project.yml` (add the target; register it in `scheme.testTargets`)
- Modify: `Makefile` (`uitest` target + rule, `.PHONY`, narrow `TEST_INPUTS`)

**Interfaces:**
- Consumes: `UITestFixture.seed(canonicalAt:now:)` and `UITestFixture.ID` from Task 3.
- Produces:
  - `func launchPensieve(seededAt now: Date, locale: String?) -> XCUIApplication` in `AppLaunch.swift`, used by every later UI test.

**Context an implementer needs:**

`GENERATE_INFOPLIST_FILE: "YES"` is **required** — without it xcodebuild fails with *"Cannot code sign because the target does not have an Info.plist file"*. This was hit and fixed during the spike.

XCUITest launches a **second** instance even while the live app runs; this is measured, not hoped for. Tests must not assume the live app is quit.

Defaults isolation (spec §3.1): reads are pinned through `launchArguments` (the argument domain outranks every other defaults domain, including `@AppStorage`), and writes are contained by exporting/restoring the domain in `make uitest`. Do **not** add a production seam for this.

`TEST_INPUTS` currently globs all of `Tests/`, so without narrowing it, editing a UI test re-runs the whole SwiftPM suite. `swift test` never builds this target.

- [ ] **Step 1: Add the UI test target to `project.yml`**

Insert before the `PensieveSyncAgent:` target:

```yaml
  PensieveUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - Tests/PensieveUITests
    dependencies:
      - target: Pensieve
      - package: PensieveKit
        product: PensieveKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: me.mazetti.pensieve.uitests
        # Required: without it xcodebuild refuses to code sign the test bundle.
        GENERATE_INFOPLIST_FILE: "YES"
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_ALLOWED: "YES"
        CODE_SIGNING_REQUIRED: "NO"
        SWIFT_VERSION: "6.0"
        TEST_TARGET_NAME: Pensieve
```

And change the app target's scheme block from `testTargets: []` to:

```yaml
    scheme:
      testTargets:
        - PensieveUITests
```

- [ ] **Step 2: Write the shared launch helper**

Create `Tests/PensieveUITests/AppLaunch.swift`:

```swift
import XCTest
import PensieveKit

/// Launches a fresh Pensieve against a seeded throwaway store.
///
/// Every read of UserDefaults is pinned through the argument domain, which outranks every other
/// defaults domain (including @AppStorage). Without this the app inherits the developer's live Focus
/// context and silently filters the fixture. Writes are contained by `make uitest`, which exports and
/// restores the real domain around the suite.
func launchPensieve(seededAt now: Date = Date(), locale: String? = nil) throws -> XCUIApplication {
  let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pensieve-uitest-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

  let canonical = directory.appendingPathComponent("pensieve.sqlite")
  try UITestFixture.seed(canonicalAt: canonical, now: now)

  let application = XCUIApplication()
  application.launchEnvironment["PENSIEVE_DB"] = canonical.path
  application.launchEnvironment["PENSIEVE_CAPTURE_DB"] =
    directory.appendingPathComponent("capture.sqlite").path

  application.launchArguments += [
    "-focusFilterActiveContext", "",   // no Focus filtering, whatever the developer's Mac is doing
    "-app.narrationEnabled", "NO",     // narration is an LLM call; never in a test
    "-hideDockIcon", "NO",
  ]
  if let locale {
    application.launchArguments += ["-AppleLanguages", "(\(locale))"]
  }

  application.launch()
  return application
}
```

> **Implementer note:** the three default keys above are spelled from `AppDefaults.swift` and
> `FocusFilterDefaults`. Open `Sources/PensieveApp/AppDefaults.swift` and
> `Sources/PensieveApp/AppIntents/PensieveFocusFilter.swift` and copy the **exact** key strings. A
> mis-spelled argument-domain key fails silently — the app just uses its real value.

- [ ] **Step 3: Write the launch smoke test**

Create `Tests/PensieveUITests/LaunchSmokeTests.swift`:

```swift
import XCTest

final class LaunchSmokeTests: XCTestCase {
  /// The check the old CLAUDE.md recipe only appeared to make: that app code actually runs.
  /// AppModel.start() runs from a .task on a rendered view body, so asserting on rendered content
  /// is the only way to know the app booted rather than merely launched.
  func testWindowRendersSeededContent() throws {
    let application = try launchPensieve()

    let window = application.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 30), "no window appeared")

    XCTAssertTrue(application.staticTexts["Briefing"].waitForExistence(timeout: 15),
                  "sidebar never rendered — the app launched but no view body ran")

    // Proof the fixture reached the UI, not just that chrome drew.
    XCTAssertTrue(application.staticTexts["Colibri"].waitForExistence(timeout: 15),
                  "fixture node 'Colibri' is missing from the tree")

    let screenshot = XCTAttachment(screenshot: window.screenshot())
    screenshot.name = "launch-seeded"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}
```

- [ ] **Step 4: Add `make uitest` and narrow `TEST_INPUTS`**

In `Makefile`, change:

```make
TEST_INPUTS := Package.swift $(shell find Sources/PensieveKit Tests ! -name '.*')
```

to:

```make
# Tests/ narrowed to the SwiftPM suite on purpose: `swift test` never builds the UI test target, so
# globbing all of Tests/ would re-run the whole suite on every UI-test edit.
TEST_INPUTS := Package.swift $(shell find Sources/PensieveKit Tests/PensieveKitTests ! -name '.*')
UITEST_SOURCES := $(shell find Tests/PensieveUITests -type f -name '*.swift')
```

Add `uitest` to `.PHONY`, and add the rule:

```make
uitest: .make/uitest ## Run the app UI test suite (launches a real window; not part of `all`)

# Deliberately outside `all`: this launches a real GUI window and holds focus for ~35s, which would
# make the most-run command hostile to work alongside.
#
# The app writes its own defaults (lastOpenedAt among them), and a test run must not shift the real
# Briefing baseline — so the domain is exported and restored around the suite. Best-effort: a crash
# mid-suite skips the restore, but the export is still on disk at the path below.
.make/uitest: $(APP_CLI) $(UITEST_SOURCES) | .make
	@defaults export me.mazetti.pensieve /tmp/pensieve-defaults-backup.plist 2>/dev/null || true
	@xcodebuild $(XCODEBUILD_FLAGS) -scheme Pensieve -only-testing:PensieveUITests test \
		|| (defaults import me.mazetti.pensieve /tmp/pensieve-defaults-backup.plist 2>/dev/null; exit 1)
	@defaults import me.mazetti.pensieve /tmp/pensieve-defaults-backup.plist 2>/dev/null || true
	@touch $@
```

- [ ] **Step 5: Regenerate and run**

```bash
make generate && make uitest
```
Expected: `** TEST SUCCEEDED **`. A window appears for ~15 s and closes.

If it fails with *"Cannot code sign … Info.plist"*, `GENERATE_INFOPLIST_FILE` is missing from Step 1.

- [ ] **Step 6: Verify the screenshot round-trip**

```bash
LATEST=$(ls -dt .build-xcode/Logs/Test/*.xcresult | head -1)
xcrun xcresulttool export attachments --path "$LATEST" --output-path /tmp/uitest-shots
ls /tmp/uitest-shots
```
Expected: a PNG plus `manifest.json`. Open the PNG and confirm it shows the **fixture** (Colibri, Work), not your live 182-project store. If it shows the live store, `PENSIEVE_DB` is not reaching the app.

- [ ] **Step 7: Verify the defaults guard and the make caching**

```bash
defaults read me.mazetti.pensieve lastOpenedAt 2>/dev/null; make uitest; defaults read me.mazetti.pensieve lastOpenedAt 2>/dev/null
```
Expected: the value is unchanged across the run (or absent both times).

```bash
make uitest
```
Expected: second run does nothing (cached). Then confirm the SwiftPM record is independent:

```bash
touch Tests/PensieveUITests/LaunchSmokeTests.swift && make test
```
Expected: **no** SwiftPM suite re-run — proof `TEST_INPUTS` was narrowed correctly.

- [ ] **Step 8: Commit**

```bash
git add project.yml Makefile Tests/PensieveUITests
git commit -F - <<'EOF'
feat: add the PensieveUITests target and make uitest

This is the app target's first real automated signal. The recipe it replaces
-- background the inner Mach-O, then kill it -- exercised no app code at all,
because AppModel.start() runs from a .task on a rendered view body. Asserting
on rendered fixture content is the only way to know the app booted.

Kept out of `make all`: it launches a real window and holds focus for ~35s.
The real defaults domain is exported and restored around the suite so a test
run cannot shift the developer's Briefing baseline.
EOF
```

---

### Task 5: The substantive UI tests

**Files:**
- Create: `Tests/PensieveUITests/DetailOrderTests.swift`
- Create: `Tests/PensieveUITests/SidebarCountTests.swift`
- Create: `Tests/PensieveUITests/LocalizationTests.swift`

**Interfaces:**
- Consumes: `launchPensieve(seededAt:locale:)` from Task 4; `UITestFixture.colibriOpenLooseEndText` and `.colibriOpenLooseEndQuote` from Task 3.
- Produces: nothing consumed by later tasks.

**Context an implementer needs:**

These target the carries that recur most across slices. The loose-ends-before-recap ordering is the one that **neither the slice-A nor the in-node-find branch could have caught alone** — it only broke in their combination, which is exactly the class of bug a permanent suite earns its keep on.

Ordering is asserted by comparing element **frames** (`frame.minY`), not by index in a query result — query order is not a documented rendering order.

The German test is the one that proves the argument domain reaches the app at all: if `-AppleLanguages` were ignored, the app would render English and the assertion would fail loudly.

Every test needs a node selected first. Use `application.staticTexts["Colibri"].click()` — XCUIElement `click()` is the supported macOS interaction and does not need the `uiprobe` AXSelected workaround (that exists for out-of-process driving, where XCUITest's affordances are unavailable).

- [ ] **Step 1: Write the detail-order test**

Create `Tests/PensieveUITests/DetailOrderTests.swift`:

```swift
import XCTest
import PensieveKit

final class DetailOrderTests: XCTestCase {
  /// Slice A moved the recap below the loose ends. The in-node-find branch, developed in parallel,
  /// still emitted the narration slot first — ⌘G walked document order, so the two together produced
  /// a defect neither branch could catch alone. This pins the rendered order.
  func testLooseEndsRenderAboveTheRecap() throws {
    let application = try launchPensieve()

    let colibri = application.staticTexts["Colibri"]
    XCTAssertTrue(colibri.waitForExistence(timeout: 20), "fixture tree never rendered")
    colibri.click()

    let looseEnd = application.staticTexts[UITestFixture.colibriOpenLooseEndText]
    XCTAssertTrue(looseEnd.waitForExistence(timeout: 15), "the open loose end never rendered")

    // The recap is the only prose block below the loose ends; find it by its own container.
    // If narration is disabled there is no recap at all, which is the correct empty case — the
    // ordering claim is then vacuously true and the test only pins the loose end's presence.
    let recap = application.staticTexts.matching(
      NSPredicate(format: "value CONTAINS[c] %@", "Hummingbird ingest pipeline")
    ).firstMatch
    guard recap.exists else { return }

    XCTAssertLessThan(looseEnd.frame.minY, recap.frame.minY,
                      "the recap rendered above the loose ends")
  }

  /// The cited quote is rendered verbatim: it is the trust gate's visible output.
  func testCitedQuoteRendersVerbatim() throws {
    let application = try launchPensieve()

    let colibri = application.staticTexts["Colibri"]
    XCTAssertTrue(colibri.waitForExistence(timeout: 20))
    colibri.click()

    let quoted = application.staticTexts.containing(
      NSPredicate(format: "value CONTAINS %@", UITestFixture.colibriOpenLooseEndQuote)
    ).firstMatch
    XCTAssertTrue(quoted.waitForExistence(timeout: 15),
                  "the cited quote is missing or was altered — provenance must render verbatim")
  }
}
```

- [ ] **Step 2: Run it**

```bash
make -B uitest
```
Expected: both tests pass. If `testLooseEndsRenderAboveTheRecap` cannot find the loose end, dump the tree from the *running* fixture instance to see what actually rendered — launch it by hand and use the probe:

```bash
./.build/uiprobe windows          # find the fixture instance's pid
./.build/uiprobe dump --pid <pid> --grep 'retry shim'
```

- [ ] **Step 3: Write the sidebar-count test**

Create `Tests/PensieveUITests/SidebarCountTests.swift`:

```swift
import XCTest

final class SidebarCountTests: XCTestCase {
  /// The counts are the feature: before loose ends could be resolved, "Als Nächstes 155" never
  /// shrank and so meant nothing. The fixture has exactly 3 open loose ends and 1 archived node.
  func testSidebarShowsFixtureCounts() throws {
    let application = try launchPensieve()
    XCTAssertTrue(application.staticTexts["Briefing"].waitForExistence(timeout: 20))

    XCTAssertTrue(application.staticTexts["3"].exists,
                  "expected the open-loose-end count of 3 from the fixture")

    // The archived node must NOT appear in the normal tree.
    XCTAssertFalse(application.staticTexts["Old Prototype"].exists,
                   "an archived node leaked into the main tree")
  }
}
```

- [ ] **Step 4: Write the localization test**

Create `Tests/PensieveUITests/LocalizationTests.swift`:

```swift
import XCTest

final class LocalizationTests: XCTestCase {
  /// German chrome, English content. This also proves the argument domain reaches the app: if
  /// -AppleLanguages were ignored the app would render English and this would fail loudly.
  func testGermanChromeWithEnglishContent() throws {
    let application = try launchPensieve(locale: "de")
    XCTAssertTrue(application.staticTexts["Briefing"].waitForExistence(timeout: 20))

    // Chrome is localized.
    XCTAssertTrue(application.staticTexts["Als Nächstes"].exists,
                  "sidebar chrome did not render in German")
    XCTAssertTrue(application.staticTexts["Lose Enden"].exists)

    // Content is never localized — node names come from the canonical store verbatim.
    XCTAssertTrue(application.staticTexts["Colibri"].exists,
                  "a node name was localized; content must stay verbatim")
  }
}
```

- [ ] **Step 5: Run the full UI suite**

```bash
make -B uitest
```
Expected: 4 tests, all passing.

Any assertion that fails because a label differs from what this plan guessed is a **plan error, not a product bug** — fix the expected string to match what the app renders (confirm with `uiprobe dump --grep`), do not change the app.

- [ ] **Step 6: Commit**

```bash
git add Tests/PensieveUITests
git commit -F - <<'EOF'
test: pin detail ordering, sidebar counts and German chrome

The ordering test covers the defect neither slice A nor in-node find could
catch alone: slice A moved the recap below the loose ends while the parallel
branch still emitted the narration slot first. Ordering is asserted on frame
geometry, not query order, which is not a documented rendering order.

The German test doubles as proof that the argument domain reaches the app --
if -AppleLanguages were ignored the app would render English.
EOF
```

---

### Task 6: The skill, and retiring the recipe it replaces

**Files:**
- Create: `.claude/skills/verify-app-ui/SKILL.md`
- Modify: `.gitignore` (un-ignore `.claude/skills/`)
- Modify: `CLAUDE.md` (replace the broken app smoke recipe; add `make uiprobe`/`make uitest`)

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: the skill future sessions load.

**Context an implementer needs:**

`.gitignore` line 20 ignores all of `.claude/`. Git **cannot** re-include a path whose parent directory is excluded, so `!.claude/skills/` alone does nothing — the exclusion must be narrowed to `.claude/*` first.

`CLAUDE.md` currently instructs: *"Verify with an `xcodebuild` build + a non-blocking smoke-launch of the inner binary"*. That recipe exercises no app code. It must go, or the next session will follow it.

- [ ] **Step 1: Un-ignore the skills directory**

In `.gitignore`, replace:

```gitignore
# Claude Code worktree checkouts
.claude/
```

with:

```gitignore
# Claude Code worktree checkouts. Narrowed to `/*` so skills can be re-included:
# git cannot re-include a path whose parent directory is excluded.
.claude/*
!.claude/skills/
```

Verify:

```bash
git check-ignore -v .claude/skills/verify-app-ui/SKILL.md; echo "exit=$?"
```
Expected: `exit=1` (not ignored). And confirm worktrees are still ignored:

```bash
git check-ignore -v .claude/worktrees; echo "exit=$?"
```
Expected: `exit=0` (still ignored).

- [ ] **Step 2: Write the skill**

Create `.claude/skills/verify-app-ui/SKILL.md`:

````markdown
---
name: verify-app-ui
description: Use when verifying any change to Sources/PensieveApp — checking that a SwiftUI view renders what was specified, that ordering/labels/counts are right, that German localization landed, or when tempted to ask the user to click through the app and send a screenshot. Covers the uiprobe accessibility tool and the PensieveUITests suite.
---

# Verifying the Pensieve app UI

The app target has no unit tests. These two loops are how a UI change gets verified
without the user clicking through it.

## Which loop — decide before you run anything

1. **Accessibility tree first** (`make uiprobe`, ~1 s). Structure, ordering, labels,
   counts, selection, localization. Most questions are this kind.
2. **Pixels only for genuinely visual questions** (`uiprobe shot`). Type scale, spacing,
   truncation, icon artwork, overlap. Screenshots cost far more tokens to read and answer
   less precisely — do not reach for one to answer a question the tree already answers.
3. **XCUITest** (`make uitest`, ~35 s) for **anything that writes**, and for anything that
   must stay true.

**Hard rule: the live app is read-and-navigate only.** Rename, merge, archive, resolve,
new node — all of it goes through `make uitest` against a fixture store. Never drive a
write path against `~/Library/Application Support/Pensieve/`; that is the user's real
182-project store.

## Loop 1 — driving the live app

```bash
make uiprobe                                    # builds ./.build/uiprobe (cached)
./.build/uiprobe windows                        # pid, window id, title, bounds
./.build/uiprobe dump --grep 'Als Nächstes'     # filtered tree — start here
./.build/uiprobe dump --depth 8                 # whole tree, bounded
./.build/uiprobe find "Briefing"                # role, frame, attributes
./.build/uiprobe select "Abgeschlossen"         # sidebar/list rows
./.build/uiprobe click "Refresh"                # buttons and non-row controls
./.build/uiprobe key cmd+f                      # cmd+f, shift+cmd+g, escape, literal text
./.build/uiprobe shot --out /tmp/window.png     # then read the PNG
```

Non-zero exit means not-found, so a missed lookup is distinguishable from an empty result.

**Put the app back where you found it.** If you navigate away, navigate back.

## Loop 2 — the deterministic suite

```bash
make uitest        # cached; use `make -B uitest` to force
```

Launches a **second** app instance against a temp store seeded by
`UITestFixture.seed(canonicalAt:now:)` (PensieveKit, tested in `UITestFixtureTests`). The
live app may keep running — measured, not assumed.

Recover screenshots from the result bundle:

```bash
LATEST=$(ls -dt .build-xcode/Logs/Test/*.xcresult | head -1)
xcrun xcresulttool export attachments --path "$LATEST" --output-path /tmp/uitest-shots
```

Add a test by copying an existing one in `Tests/PensieveUITests/` and using
`launchPensieve(seededAt:locale:)`. Assert **ordering on `frame.minY`**, never on query
order — query order is not a documented rendering order.

## Gotchas

- **Missing TCC grants.** `uiprobe windows` printing `<no title — Screen Recording not
  granted>` means Screen Recording is missing. `dump` failing with "no accessible windows"
  means Accessibility is missing. Both are granted **per host process**, so a different
  terminal needs its own one-time grant in System Settings ▸ Privacy & Security.
- **Two instances.** A fixture instance and the live app share `me.mazetti.pensieve`.
  `uiprobe` refuses to guess and tells you to pass `--pid`; get pids from `uiprobe windows`.
- **SwiftUI rows have no `AXPress`.** `select` sets `AXSelected` on the nearest `AXRow`.
  If `select` fails on something that is not a row, use `click`.
- **Stale bundle.** Launch the installed app with `make run`, never Spotlight — every
  worktree build registers another bundle under the same id and LaunchServices picks
  between them. A month-old build on screen reads as a regression.
- **A failing assertion on a *label* is usually this plan's error, not a product bug.**
  Confirm what the app actually renders with `uiprobe dump --grep` before changing code.

## What this does not cover

Taste. These loops verify the UI **is what was specified**; whether it *looks right* —
balance, hierarchy, whether a German string reads naturally in situ — is still the user's
call. The human-verify ledger shrinks; it does not empty.
````

- [ ] **Step 3: Update `CLAUDE.md`**

In the *Conventions & gotchas* section, replace the bullet beginning **"The app (`Sources/PensieveApp/`) has no unit tests"** with:

```markdown
- **The app (`Sources/PensieveApp/`) has no unit tests** — it's an Xcode app target, not covered by `PensieveKitTests`. Verify with **`make uitest`** (XCUITest over a seeded fixture store) and **`make uiprobe`** (an accessibility probe that reads and drives the *running* app). See the `verify-app-ui` skill. **The old recipe — build, then background the inner binary and kill it — is retired: it exercised no app code at all**, because `AppModel.start()` runs from a `.task` on a rendered view body, so a backgrounded direct-exec never renders one. Keep derivation logic (bucketing, tree/card building, ranking) in **tested PensieveKit**; keep views thin. App reads are read-only; the only canonical writer is still `Ingester.drain()`.
```

In the *Build & test* section, add after the `make` targets bullet:

```markdown
- **`make uiprobe`** builds `./.build/uiprobe`, an accessibility probe for the *running* app (`windows`/`dump`/`find`/`select`/`click`/`key`/`shot`). **`make uitest`** runs the XCUITest suite against a seeded fixture store; it is deliberately **not** part of `make all` (it launches a real window and holds focus ~35 s). Both are documented in the `verify-app-ui` skill.
```

- [ ] **Step 4: Verify the skill is committable and the docs are consistent**

```bash
git status --porcelain .claude/skills
```
Expected: the `SKILL.md` shows as untracked (`??`), proving the un-ignore worked.

```bash
grep -n "smoke-launch" CLAUDE.md; echo "exit=$?"
```
Expected: `exit=1` — no match. The broken recipe is gone. (The original grep here searched for `smoke-launch of the inner binary`, which never matched even while the recipe was live, because CLAUDE.md emphasises `**inner binary**`. It would have passed without the removal happening.)

- [ ] **Step 5: Full verification**

```bash
make all && make uitest
```
Expected: lint clean, 755 tests green, app builds, CLI smoke passes, 4 UI tests pass.

- [ ] **Step 6: Commit**

```bash
git add .gitignore .claude/skills CLAUDE.md
git commit -F - <<'EOF'
docs: add the verify-app-ui skill and retire the recipe it replaces

CLAUDE.md told the next session to verify app changes by backgrounding the
inner binary and killing it. That exercises no app code, because
AppModel.start() runs from a .task on a rendered view body -- it has been
passing while proving nothing, which is worse than having no check.

.gitignore ignored all of .claude/, so the skill would have been lost on a
fresh clone. Git cannot re-include a path whose parent directory is
excluded, so the exclusion is narrowed to .claude/* first.
EOF
```

---

## Self-Review

**Spec coverage.** §1 `uiprobe` → Tasks 1–2. §2 `PensieveUITests` → Task 4. §3 seeder → Task 3. §3.1 defaults isolation → Task 4 Steps 2 and 4. §4 `make uitest` + Makefile corrections → Task 4 (`TEST_INPUTS`, `uitest`) and Task 1 (lint scope, both edits). §5 skill + `.gitignore` → Task 6. The spec's "out of scope" items (CI, pixel-diffing, Settings/menu-bar coverage, replacing `make smoke`) have no tasks, correctly. Retiring the broken `CLAUDE.md` recipe — flagged in the spec as a plan-level concern — is Task 6 Step 3.

**Known soft spots**, called out rather than hidden:
- The exact rendered labels in Task 5 (`"3"`, `"Als Nächstes"`, the recap's text) are inferred from the live app's tree and the fixture, not verified against a fixture-backed launch, which cannot exist before Task 4. Task 5 Step 5 says explicitly that a label mismatch is a plan error to fix in the test, not a product bug to fix in the app.
- The SQLiteData insert spelling in Task 3 is given as `try Node.insert { node }.execute(db)`; the task directs the implementer to read `CanonicalStoreTests.swift` and match its idiom exactly, since that file is the authority.
- The `namedKeys` table in Task 2 covers only the keys this repo's shortcuts use. Extending it is a one-line change when a new chord is needed.
