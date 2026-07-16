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
new packages in project.yml:  sqlite-data (from 1.6.0), swift-argument-parser (from 1.5.0),
                              swift-sdk (exact 0.12.1)     (pins mirror Package.swift verbatim)
```

- The `pensieve` tool target keeps its **exact** sources — all 25 subcommands, `openCanonicalReadOnly`,
  everything. It ships as-is, **including `eval`** (stripping a dev subcommand is extra work for no
  gain — YAGNI). Note: `eval` resolves `.eval/` + `eval-config.json` **cwd-relative** (`EvalPaths`), so
  a shipped `pensieve eval` run from `~` would create `~/.eval/` and find no config → graceful
  empty-roster fallback. Dev-only, harmless; called out so it isn't mistaken for a bug.
- **CLI-only SPM deps move to `project.yml`.** The CLI directly `import`s **`ArgumentParser`, `MCP`,
  *and* `SQLiteData`** (verified: `Pensieve.swift`, `Group.swift`, `Mcp.swift` — `openCanonicalReadOnly`
  returns `any DatabaseReader`, a SQLiteData type; PensieveKit does **not** `@_exported` it). So all
  **three** packages — `sqlite-data`, `swift-argument-parser`, `swift-sdk` — must be declared in
  `project.yml`'s `packages:` (with the pins above), and the tool target lists `product: SQLiteData`,
  `product: ArgumentParser`, `product: MCP`. "Transitive via PensieveKit" is false for `import`
  resolution.
- **Target identity.** The tool sets an explicit `PRODUCT_BUNDLE_IDENTIFIER: me.mazetti.pensieve.cli` —
  without it XcodeGen defaults to `bundleIdPrefix + ".pensieve"` = `me.mazetti.pensieve`, **colliding
  with the app**. (Mirrors how `PensieveSyncAgent` sets `me.mazetti.pensieve.sync`.)
- **Dev-loop change:** `swift run pensieve …` is **gone**. XcodeGen does **not** emit a shared scheme
  per target by default (only the app has one, via its `scheme:` block) — so a bare
  `xcodebuild -scheme pensieve` would fail. The tool target therefore gets its **own minimal `scheme:`
  block** in `project.yml`, restoring `xcodebuild -scheme pensieve build` as the standalone CLI build.
  (Building the app scheme also compiles + embeds the CLI.) Kit iteration is unchanged (`swift test`).

## The symlink install logic — a tested PensieveKit kernel

The bundled binary lives inside the app; the things that call the CLI are **external** — git hooks,
`~/.claude/settings.json` (`capture-session-start/end`, `prime`), and `claude mcp add pensieve --
pensieve mcp` — and today they resolve `~/.local/bin/pensieve`. A **symlink**
`~/.local/bin/pensieve → /Applications/Pensieve.app/Contents/Helpers/pensieve` bridges them with **zero
changes to existing configs**. Because the symlink points at the stable `/Applications` path, the app
updates *in place behind it* — there is no per-update reinstall. This is precisely the VS Code `code` /
`gh` "install command-line tool" idiom.

Caveat (review finding #5): git + session hooks embed an **absolute** path, so they are PATH-independent
and the symlink fully serves them. But `claude mcp add pensieve -- pensieve mcp` stores the **bare token
`pensieve`**, resolved via `$PATH` at runtime — the symlink only helps if `~/.local/bin` is on the
user's `PATH`. It is on the dogfooding machine (the current setup works). **Managing/validating `PATH`
membership is out of scope** — the design assumes it, and the Settings status reflects the symlink's
existence, not PATH reachability.

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
  3. `switch CLIToolInstaller.plan(...)`: **only `.create` auto-applies at launch** → `try? apply(...)`
     (silent; a `mkdir -p` + symlink is cheap enough to run inline — unlike background-sync's legacy
     `launchctl` boot-out, this needs no off-main hop). `.upToDate` → nothing. `.repoint` and
     `.blockedRealFile` → **do nothing at launch**; surface them in Settings only. Rationale (review
     finding): a symlink-pointing-elsewhere is indistinguishable from a *deliberate* user symlink to a
     second install/dev build, so silently repointing it at launch could hijack the user's intent;
     repointing is therefore an explicit Settings action. `.create` writes into an empty path, so its
     mutation is a plain create (no non-atomic remove+create window, and no risk to a running CLI).
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
- **`project.yml`:** add the `pensieve` tool target (deps: PensieveKit + `SQLiteData` + `ArgumentParser`
  + `MCP`; ad-hoc signing block + explicit `me.mazetti.pensieve.cli` bundle id + a minimal `scheme:`
  block; otherwise matching `PensieveSyncAgent`); add it to the app target's `dependencies:` with
  `embed: true, codeSign: true, copy: { destination: wrapper, subpath: Contents/Helpers }`. The CLI
  goes in `Contents/Helpers/` (the conventional bundled-CLI location, e.g. Sparkle) — deliberately
  distinct from `PensieveSyncAgent`'s `Contents/Library/Helpers/`, which is a launchd/SMAppService
  helper, a different kind of thing. Both are valid signed locations for an ad-hoc bundle.
- **Hook-install commands emit the symlink path, not the resolved bundle path (review finding #4).**
  `InstallHooks`, `InstallSessionHook`, and `Scan` currently write `Bundle.main.executablePath` into the
  generated git/Claude-Code hook configs. Run *through* the symlink, `Bundle.main.executablePath`
  resolves to `/Applications/Pensieve.app/Contents/Helpers/pensieve`, so a **fresh** `install-*` after
  migration would hard-code the bundle path and lose the symlink indirection (breaking on an app
  move/rename). Point all three at the already-existing `PensievePaths.installedBinaryURL()` (=
  `~/.local/bin/pensieve`) instead, so newly-written configs match the existing ones and stay durable.
  Existing configs are unaffected (they already reference `~/.local/bin/pensieve`).
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

**In scope:** the `pensieve` Xcode `tool` target (explicit `me.mazetti.pensieve.cli` id + `scheme:`
block) + bundle embedding at `Contents/Helpers/`; `Package.swift` executable removal + the three
CLI-only package deps (`sqlite-data`, `swift-argument-parser`, `swift-sdk`) moved to `project.yml`;
the tested `CLIToolInstaller` Kit kernel; `AppDelegate` launch wiring (guarded; auto-applies `.create`
only); the Settings "Command-line tool" section (status + install/repair/replace) + German l10n;
repointing the three hook-install commands (`InstallHooks`/`InstallSessionHook`/`Scan`) at
`PensievePaths.installedBinaryURL()`; docs/runbook updates.

**Out of scope / deferred:** collapsing PensieveKit/tests into Xcode; notarization/Developer-ID
signing; a CLI CI target; rewriting existing hook configs (the symlink makes that unnecessary);
changing any CLI subcommand behavior.
