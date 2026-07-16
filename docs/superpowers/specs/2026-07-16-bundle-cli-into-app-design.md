# Bundle the `pensieve` CLI into the app — design

**Status:** approved (brainstorm). Not yet planned.
**Roadmap:** build-system consolidation follow-up to the SMAppService background-sync work
(`docs/superpowers/specs/2026-07-14-background-sync-smappservice-agent-design.md`), which established
the bundled-helper (`PensieveSyncAgent`) pattern this reuses.

## Why

The `pensieve` CLI is a SwiftPM `executableTarget` distributed by hand: `swift build -c release && cp
.build/release/pensieve ~/.local/bin/pensieve`. That copy **drifts** from the app — every feature that
touches PensieveKit ends a runbook with *"rebuild + reinstall the release CLI"*, and a stale
`~/.local/bin/pensieve` silently runs old logic against the shared stores. The CLI is not part of the
portable **library** (PensieveKit holds all logic + all tests); it is a *front-end on the library*,
exactly like the app. It therefore belongs to the **app build**, shipped inside `Pensieve.app` and
version-coherent with it by construction.

`PensieveSyncAgent` already proves the pattern: a small Xcode `tool` target, ad-hoc signed, embedded in
the bundle. The CLI becomes a second such target.

## What stays put (explicit non-goals)

- **PensieveKit + PensieveKitTests stay SwiftPM.** `swift test` remains the fast, headless, Xcode-free
  core dev loop (`./scripts/test.sh`). This change does **not** collapse the library or its tests into
  Xcode; it only moves the *CLI executable*.
- **Signing stays ad-hoc** (`CODE_SIGN_IDENTITY: "-"`); no Developer-ID / notarization.
- **No CI target for the CLI** (no CI exists today).
- **The trust gate, capture path, stores, hooks — all untouched.** This is a packaging change.

## Target topology

`Sources/pensieve/` stops being a SwiftPM product and becomes an Xcode `tool` target, a sibling of
`PensieveSyncAgent`, embedded + signed into the bundle at `Contents/Helpers/pensieve`.

```
Package.swift   →  library(PensieveKit) + PensieveKitTests only     (no .executable("pensieve"))
project.yml     →  Pensieve.app
                     ├── embeds  pensieve          (tool) → Contents/Helpers/pensieve
                     └── embeds  PensieveSyncAgent  (tool) → Contents/Library/Helpers/PensieveSyncAgent
new packages in project.yml:  swift-argument-parser, swift-sdk (MCP)   (CLI-only deps)
```

- The `pensieve` tool target keeps its **exact** sources — all 25 subcommands, `openCanonicalReadOnly`,
  everything. It ships as-is, **including `eval`** (stripping a dev subcommand is extra work for no
  gain — YAGNI).
- **Dev loop change:** `swift run pensieve …` is **gone**. The CLI is now built via
  `xcodebuild -scheme pensieve build` (XcodeGen emits a per-target scheme) and run from the built
  product, or via the bundled binary after an app build. Kit iteration is unchanged (`swift test`).
- `swift-argument-parser` and `swift-sdk` (the MCP SDK) move from `Package.swift`'s dependency list
  into `project.yml`'s `packages:` (they are consumed only by the CLI target now). `SQLiteData` is
  already reachable transitively via PensieveKit; the CLI target declares whatever products it directly
  imports.

## The symlink install logic — a tested PensieveKit kernel

The bundled binary lives inside the app; the things that call the CLI are **external** — git hooks,
`~/.claude/settings.json` (`capture-session-start/end`, `prime`), and `claude mcp add pensieve --
pensieve mcp` — and today they resolve `~/.local/bin/pensieve`. A **symlink**
`~/.local/bin/pensieve → /Applications/Pensieve.app/Contents/Helpers/pensieve` bridges them with **zero
changes to existing configs**. Because the symlink points at the stable `/Applications` path, the app
updates *in place behind it* — there is no per-update reinstall. This is precisely the VS Code `code` /
`gh` "install command-line tool" idiom.

Per the house rule (logic in tested Kit; app stays thin), the decision of *what to do* is a **pure Kit
function**, not app code. New `Sources/PensieveKit/Support/CLIToolInstaller.swift`:

```swift
public enum CLIToolInstaller {
  public enum Plan: Equatable {
    case create           // path absent → make the symlink
    case upToDate         // already our symlink, correct target → no-op
    case repoint          // a symlink, but wrong/stale target → replace it
    case blockedRealFile  // a regular file lives there (legacy hand-copied binary) → DO NOT touch
  }

  /// Pure: inspect the current filesystem state at `linkPath` and decide the action needed to make it
  /// point at `desiredTarget`. Does not mutate anything.
  public static func plan(linkPath: URL, desiredTarget: URL, fileManager: FileManager = .default) -> Plan

  /// Thin mutation for the safe plans (.create / .repoint): mkdir -p ~/.local/bin, then create/replace
  /// the symlink. `.blockedRealFile` and `.upToDate` are no-ops here (caller gates on them).
  public static func apply(_ plan: Plan, linkPath: URL, desiredTarget: URL, fileManager: FileManager = .default) throws

  /// Explicit, destructive: remove whatever is at `linkPath` (incl. a real file) and create the symlink.
  /// Only ever called from the Settings "Replace legacy binary" confirmation — never at launch.
  public static func replace(linkPath: URL, desiredTarget: URL, fileManager: FileManager = .default) throws
}
```

`plan` distinguishes the four states by `FileManager` attributes: absent → `.create`; a symlink whose
`destinationOfSymbolicLink` resolves to `desiredTarget` → `.upToDate`; a symlink resolving elsewhere →
`.repoint`; a regular file (or anything not a symlink) → `.blockedRealFile`. The guard against managing
from a throwaway build reuses the existing `BackgroundSyncGuard.shouldManage(bundlePath:)` (same
"refuse from `/.build`" rule) — **no new guard type**.

## App wiring (thin)

- **Launch** — a new `configureCommandLineTool()` in `AppDelegate.applicationDidFinishLaunching`,
  mirroring the existing `configureBackgroundSync()`:
  1. `guard BackgroundSyncGuard.shouldManage(bundlePath: Bundle.main.bundlePath)` (installed app only —
     a `.build-xcode` smoke-launch must never write `~/.local/bin`).
  2. `desiredTarget = Bundle.main.bundleURL/Contents/Helpers/pensieve`;
     `linkPath = ~/.local/bin/pensieve`.
  3. `switch CLIToolInstaller.plan(...)`: `.create` / `.repoint` → `try? apply(...)` (silent; a
     `mkdir -p` + symlink is cheap enough to run inline — unlike background-sync's legacy `launchctl`
     boot-out, this needs no off-main hop); `.upToDate` / `.blockedRealFile` → do nothing. **Never**
     clobber a real file at launch.
- **Settings ▸ General ▸ "Command-line tool"** section (below Background sync):
  - A status line derived from `CLIToolInstaller.plan`:
    - `.upToDate` → "Installed"
    - `.create` → "Not installed"
    - `.repoint` → "Points elsewhere"
    - `.blockedRealFile` → "A file is in the way"
  - A button:
    - `.create` / `.repoint` → **"Install command-line tool"** / **"Repair"** → `apply(...)`.
    - `.blockedRealFile` → **"Replace existing binary"** behind a `.confirmationDialog` → `replace(...)`.
      This is the one-time migration for the current machine's real `~/.local/bin/pensieve`.
  - German l10n for the new chrome (impersonal/infinitive; "Pensieve"/"pensieve" stay English). Keys
    reconciled by hand in `Localizable.xcstrings` (xcodebuild does not auto-populate them).

The app-target wrapper (if any) is thin and hand-verified; all branching lives in the tested Kit
kernel.

## Migration & cleanup

- **This machine:** the current real `~/.local/bin/pensieve` file → the Settings **"Replace existing
  binary"** action (one explicit click) swaps it for the symlink. Self-healing thereafter.
- **`Package.swift`:** delete `.executable(name: "pensieve", targets: ["pensieve"])` from `products`
  and the `pensieve` `.executableTarget` from `targets`. Move `swift-argument-parser` + `swift-sdk`
  out of the package dependencies (they become `project.yml` packages). Leave PensieveKit + tests.
- **`project.yml`:** add the `pensieve` tool target (deps: PensieveKit + ArgumentParser + MCP;
  ad-hoc signing block matching `PensieveSyncAgent`); add it to the app target's `dependencies:` with
  `embed: true, codeSign: true, copy: { destination: wrapper, subpath: Contents/Helpers }`.
- **Docs:** `CLAUDE.md` (Dogfooding + Build/test bullets) and the plan runbooks drop *"rebuild +
  reinstall the release CLI"*; the new story is "the CLI ships inside `Pensieve.app`; install/repair the
  `~/.local/bin/pensieve` symlink once via Settings (auto on launch from `/Applications`)." Note the
  dev-loop change (`swift run pensieve` → `xcodebuild -scheme pensieve`).

## Testing & verification

- **`CLIToolInstallerTests` (Kit)** — `plan` returns the correct `Plan` for all four filesystem states
  (absent, our-symlink-correct, symlink-elsewhere, real-file), driven against a temp dir; `apply`
  creates/replaces a symlink for the safe plans and no-ops on `.blockedRealFile`/`.upToDate`;
  `replace` removes a real file and links. Pure, deterministic, no app host.
- **App:** `xcodebuild … build` succeeds; `find …/Pensieve.app/Contents/Helpers` shows a **signed**
  `pensieve` (`codesign -dv`); the guarded inner-binary smoke-launch from `.build-xcode` writes **no**
  `~/.local/bin` symlink (guard holds).
- **Human-verify carries** (need the built app installed to `/Applications`):
  - Install to `/Applications`, launch → `~/.local/bin/pensieve` becomes our symlink pointing into the
    bundle (or, with the legacy file present, Settings offers **Replace**; after the click the symlink
    exists).
  - `pensieve list` / `pensieve status` run through the symlink; a real git-commit capture hook and a
    Claude Code `SessionStart`/`prime` hook still fire (they call `~/.local/bin/pensieve` unchanged).
  - `claude mcp add pensieve -- pensieve mcp` still resolves.
  - After an app rebuild + reinstall in place, the symlink still resolves (target path stable) — no
    reinstall needed.

## Scope

**In scope:** the `pensieve` Xcode `tool` target + bundle embedding; `Package.swift` executable
removal + dependency move; the tested `CLIToolInstaller` Kit kernel; `AppDelegate` launch wiring
(guarded, non-clobbering); the Settings "Command-line tool" section (status + install/repair/replace) +
German l10n; docs/runbook updates.

**Out of scope / deferred:** collapsing PensieveKit/tests into Xcode; notarization/Developer-ID
signing; a CLI CI target; rewriting existing hook configs (the symlink makes that unnecessary);
changing any CLI subcommand behavior.
