# Custom store location — one relocatable support folder, and a readable Locations pane

**Date:** 2026-08-15
**Status:** design, ready for review
**Scope:** two things, one small and one not. (1) Settings ▸ Advanced ▸ Store & Logs is re-laid-out to
the shape Xcode's Locations pane uses — path on its own line, no monospace, a link-coloured arrow to
Finder instead of a wide button. (2) The support folder becomes a **user-settable location**, persisted
in the shared app defaults like every other setting, honoured by all five processes that resolve
Pensieve paths, and changed through a verified **move** of the existing data rather than a bare
repoint.

Deliberately excluded: per-file custom paths (one root only), a custom **Logs** location (the launchd
helper writes `sync.log` itself, and a second cross-process knob buys nothing today), sandboxing or
security-scoped bookmarks (the app is not sandboxed), and any change to the capture path's behaviour —
git hooks stay lock-free and non-blocking, by design and not by omission.

All line references are against `main` at `f51a51e`.

## Problem

### 1. The pane is cramped, and the truncation is the actual complaint

`AdvancedSettingsTab.swift:64-80` renders each location as a single-line `LabeledContent`:

```swift
LabeledContent(title) {
  HStack(spacing: 8) {
    Text(url.path)
      .font(.caption.monospaced())
      .lineLimit(1)
      .truncationMode(.middle)
      .help(url.path)
    Button("Reveal in Finder") { … }.buttonStyle(.link)
  }
}
```

Inside a `.frame(width: 460)` form (`:40`), one line has to hold a localised label, a full path, and a
~100 pt button. The path loses, and it loses in the worst available way: `.truncationMode(.middle)`
renders `/Users/moritz/Library…nsieve/pensieve.sqlite`, which is neither readable nor selectable — the
real path survives only in a tooltip. The monospace makes it worse (wider per glyph for no benefit;
these are paths, not code, and nothing here needs column alignment).

### 2. There is no way to move the data, and the paths are resolved four different times

`PensievePaths` is a pure static resolver with no user-settable layer, so the 130 MB of live store has
exactly one possible home. Worse, the "check env, else default" rule is independently re-implemented in
four places:

| Site | Resolves |
|---|---|
| `StoreOpen.swift:5-9` | spool, via `PENSIEVE_CAPTURE_DB` |
| `StoreOpen.swift:13-17` | canonical (writer), via `PENSIEVE_DB` |
| `Pensieve.swift:24-29` | canonical (read-only), via `PENSIEVE_DB` |
| `PensieveApp.swift:6-15` | both, for the app (`Stores`) |

Adding a third precedence layer to four copies is precisely the failure mode this repo keeps scarring
on — `SearchHitResolver` had to be extracted because an index filter and a canonical re-check drifted
about `isOpen`; `TranslatableCorpus` extracts its eligibility from `EmbeddableCorpus` for the same
reason. A fifth copy is not an option; the copies have to collapse first.

## Decisions already taken

Three forks were resolved before this spec was written. They are recorded here because each one
removes a large amount of design surface, and re-opening one invalidates the sections below.

**Granularity: one root.** The support folder is the only settable location. `canonicalURL`,
`captureURL`, `narrationCacheURL`, `llmScratchDirectory` and — critically — `indexURL(named:)` all
already derive from `supportDirectory()` (`PensievePaths.swift:4-62`), so moving the root moves
everything with zero per-file wiring, and no half-relocated state is representable. Logs stay at
`~/Library/Logs/Pensieve`.

**Change of location always moves the data.** A bare repoint is what Xcode does, because DerivedData is
disposable. Pensieve's canonical store is not. Repointing at an empty folder yields 0 projects and 0
loose ends with every index rebuilding from nothing — indistinguishable from total data loss, and the
same "silent, total retrieval outage" already documented at `PensievePaths.swift:30-35`. The
relocation therefore copies, verifies, commits, and closes the write window.

**A lockfile, not an agent pause.** The concurrent writer to exclude is `SyncRunner`, reached from
three callers. Pausing the `SMAppService` agent would guard only one of them while poking the
registration path this repo lost two days to in August. An advisory `flock` guards all three and never
touches Login Items.

## Design

### 1. Path resolution collapses into one resolver

```
PensievePaths.supportDirectory()
    → supportDirectory(customRoot:)          pure, no I/O, no environment read
        precedence:  PENSIEVE_* env  >  defaults key  >  ~/Library/Application Support/Pensieve
```

- **The pure sibling is mandatory, not stylistic.** `PensievePaths.indexURL(named:storeOverride:)`
  already exists in exactly this shape, and its own comment (`:44-46`) states why: `setenv` is
  process-global and Swift Testing runs suites in parallel, so a test that mutated the real source to
  cover the rule would perturb every other test reading it. A `UserDefaults` write to a shared suite
  has the identical hazard. The rule is therefore a pure function over an injected `String?`, and
  exactly one thin call site reads the world.
- **New key:** `PensieveDefaults.customSupportRootKey = "customSupportRoot"`, absolute path string,
  absent = default. It joins the existing keys in the same enum, which exists so app (writer) and
  CLI/daemon (cross-process readers) cannot drift on domain or spelling.
- **Env keeps winning**, and stays per-*file*. `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` are the test
  escape hatch; `make smoke`, `make test` and every documented verification recipe behave bit-for-bit
  as today. This also preserves the `indexURL` rule that a disposable index belongs to the store it was
  built from.
- **`Stores` in `PensieveApp.swift:6-15` is deleted**, and `AppModel.start()` (`:223`, `:225`) opens
  through the same Kit helpers as the CLI. Four copies become one.
- **The capture path stays fast.** `supportDirectory()` runs on every git-hook capture, so the shared
  `UserDefaults` handle is a `static let`, not a per-call `UserDefaults(suiteName:)` construction: one
  cached cfprefsd domain, microseconds, no new failure mode. A read that fails yields nil and the
  default path — never a throw, never a block. The capture path is sacred; this must not be the first
  thing on it that can fail.

### 2. The relocation lock

**The lock cannot live in the support directory.** `flock` binds to an inode. A same-volume rename
would preserve it and everything would appear to work; a cross-volume copy would hand the writer a
*different* inode of an identically-named file, and the guard would evaporate in precisely the case it
exists for. It anchors at a path that never relocates:

```
~/Library/Caches/me.mazetti.pensieve/relocation.lock
```

Who takes it:

| Process | Lock | Behaviour when held |
|---|---|---|
| Relocator (app) | exclusive, whole operation | — |
| `openCanonical()` — `StoreOpen.swift:13` | shared, non-blocking, **held for the writer's lifetime** | throws `StoreError.relocationInProgress` |
| `pensieve capture-*` (git hooks) → `openSpool()` | **none** | unaffected; never blocks, never fails |
| `openCanonicalReadOnly()` — `Pensieve.swift:24` (`prime`, `mcp`) | none | unaffected; reads may be stale |

`openCanonical()` is the single choke point for canonical **writers** — both `SyncRunner` construction
sites (`Sync.swift:10-15`, `PensieveSyncAgent.swift:17-22`) reach the store through it, and after §1 so
does the app. The check therefore goes in one function, not in every caller, and `SyncRunner` itself
stays pure over its injected dependencies exactly as `SyncRunner.swift:9-23` intends.

**The shared lock is held for the lifetime of the returned `DatabaseWriter`, not checked and
released.** A check-and-release would pass, return a writer, and let a relocation begin one
instruction later — the writer would then write into a directory being copied out from under it, which
is the exact race the lock exists to prevent. The lock's file descriptor is therefore owned by the
opened store and closed with it (which is also what makes a killed process release it, per test 2).

Callers treat the throw as "not now", not as an error: `pensieve sync` prints a timestamped
`relocation in progress, skipping` and exits **0**; the launchd helper logs the same line to `sync.log`
and exits 0, so the next 300 s tick picks the work up. A non-zero exit would make a routine, expected
condition look like the dead-daemon incident of 2026-08-11.

> **Implementation footgun to name explicitly:** the relocator holds the exclusive lock *in the same
> process* that would call `openCanonical()`, and would fail against itself if it did. **Every store
> the relocator opens — the source store it drains in step 1, the copy it verifies in step 4, and the
> new store it drains into in step 6 — is opened by explicit URL through `openCanonicalDatabase(at:)`
> and `CaptureSpool(at:)`, which take no lock.** That is deliberate and load-bearing, not incidental:
> the locking variants are for *other* processes. The app's own pools are closed at step 2 and
> reopened only after relaunch, so no legitimate re-entry through `openCanonical()` exists.

### 3. The relocation operation

One exclusive lock, one commit point, everything before it abortable with zero visible change.

| # | Step | On failure |
|---|---|---|
| 1 | Take exclusive lock. Drain spool → current canonical. | Lock held by a sync in flight → report "sync running, try again"; nothing changed. |
| 2 | Close the app's pools; record current `Event` count (2,723 today). | — |
| 3 | **Copy** the directory to `<destination>` — sidecars, `salience-corpus`, everything. | Delete partial destination; release; report. Old install untouched. |
| 4 | Verify: per-file byte sizes match, **and** the copied canonical store opens and reports the same `Event` count. | As above. |
| 5 | **Write `customSupportRoot`.** ← the only commit point | — |
| 6 | Re-check the *old* spool for rows a hook wrote during 3–5; drain them into the new canonical store. | Best-effort; a failure here leaves the old folder in place and is reported, never silent. |
| 7 | Move the old directory **to the Trash** via `NSWorkspace.recycle`. | Best-effort; a failure leaves 130 MB behind and says so. |
| 8 | Relaunch the app. | — |

**Copy, not `moveItem`.** `FileManager.moveItem` across volumes is internally a copy-then-delete that
can leave partial state at the destination on failure, and moving to another disk is the whole point of
the feature. Copy-verify-commit-recycle keeps the original intact and openable until after the commit
point.

**Verification is semantic, not a checksum.** Byte-size equality per file catches truncation; opening
the copied store and matching the `Event` count catches the failure that actually matters — an
unopenable or partially-written canonical store — without hashing 130 MB. Hashing would cost seconds
and prove less.

**The Trash, not `unlink`.** Native, reversible, and if anything about the new location turns out
wrong, 130 MB of canonical store is sitting in the Bin rather than gone.

**Why the app relaunches.** `AppModel` holds a `lazy var searchStore` (`:192`, unresettable by
construction), two app-lifetime `FSEventStream` watches bound to the old directories (`:241-242`), a
running `ValueObservation` task, and a narration cache keyed per DB path. Rebuilding all of that in
place is a large, fragile surface for a setting changed roughly once, and subtly getting it wrong means
the app watches a directory nothing writes to any more — a *silent* liveness failure, the worst class
available. An explicit relaunch is what Xcode does for several of its own Locations.

**Two consequences documented rather than engineered around.** Long-lived `pensieve mcp` servers held
open by running Claude Code sessions resolved their paths at startup and will read the recycled copy
until those sessions restart. `~/.local/bin/pensieve` and the git hooks need no change whatever, since
they resolve paths at every invocation.

### 4. The UI

**Width stays at 460.** All four tabs pin `.frame(width: 460)` and the window sizes to the visible tab
(`SettingsView.swift:5`), so widening one makes the window jump on every tab switch. Moving the path to
its own line reclaims more horizontal room than widening would; Xcode's pane is both wide *and*
two-line, and the second property is the one doing the work.

```
Support Folder                                    Custom  ⓘ
/Users/moritz/Library/Application Support/Pensieve        →

Canonical Store
…/Pensieve/pensieve.sqlite                                →
```

- Path in `.callout`, `.secondary`, **not monospaced**, wrapping to at most two lines. No
  `.truncationMode(.middle)` — it is unreadable and uncopyable, which is the original complaint.
- The trailing `arrow.right` is the reveal control: `.buttonStyle(.plain)`, `.foregroundStyle(.link)`,
  `.help("Reveal in Finder")`. Same `NSWorkspace.activateFileViewerSelecting` action, a fifth of the
  width.
- Only **Support Folder** carries the `Default`/`Custom` status and the ⓘ. Canonical Store, Capture
  Spool and Logs are derived and render read-only with just the arrow — an ⓘ opening a modal with no
  controls would be a lie about what is configurable.
- `Open Logs Folder` (`:34-36`) is removed; the Logs row's own arrow does that job.

**The ⓘ modal:**

```
┌────────────────────────────────────────┐
│  Location        [ Default      ⌄ ]    │
│  /Users/…/Application Support/Pensieve │
│  130 MB on disk                        │
│                            [  Done  ]  │
└────────────────────────────────────────┘
```

Selecting `Custom` opens an `NSOpenPanel` (`canChooseDirectories`, `canCreateDirectories`).
**Deliberate deviation from Xcode:** the user chooses a *container* and Pensieve uses
`<chosen>/Pensieve`, shown in full in the confirmation before anything happens. Choosing `/Volumes/Work`
and being refused for "not empty" would be maddening, and the appended component mirrors the default
layout. Selecting `Default` while custom runs the same operation in reverse.

Confirmation, stating what it is:

> **Move Pensieve's data to /Volumes/Work/Pensieve?**
> 130 MB will be copied. The old folder is moved to the Bin after verification, and Pensieve relaunches.
> — [Cancel] [Move and Relaunch]

Pre-flight refusals, each with its own message rather than a generic failure: destination not writable ·
destination inside the current root (self-copy) · destination is the current root · `<chosen>/Pensieve`
exists and is non-empty · free space on the target volume below the measured size. Progress is a
determinate bar during step 3.

### 5. Localization

~14 new keys, hand-authored in `Localizable.xcstrings` for `en` + `de`. The catalog is IDE-populated
only — `xcodebuild … build` does **not** extract keys from Swift literals — so a mis-keyed `de` value
falls back to English silently. Verified through `plutil -p` on the built bundle per the existing
recipe. Paths are content and are never localized.

## Testing

The load-bearing half is Kit and is tested; the app half is not, and this spec does not pretend
otherwise.

**Kit (Swift Testing):**

1. **Precedence**, pure over injected values: env > defaults > default, for support root and for each
   derived path. Includes the case that pins `indexURL` following a *custom root* — the regression
   this feature could most plausibly reintroduce.
2. **Lock semantics:** held exclusive → a shared acquisition fails; released → succeeds; a stale
   lockfile from a killed process does not wedge the system (flock is released on fd close, including
   on crash — assert it).
3. **`openCanonical()` throws `relocationInProgress`** while held, and `openSpool()` does **not** —
   mutation-verified in both directions, because "the hooks still work" is the property most likely to
   be quietly broken by a later edit.
4. **The relocation state machine** over an injected filesystem root, with a fault injected at each of
   steps 1–4 asserting: defaults key unwritten, destination cleaned, source intact.
5. **The step-6 window:** write a spool row *after* the copy and *before* the flip; assert it lands in
   the **new** canonical store. This is the whole reason the move story was chosen over the cheaper
   one, so it gets a test that fails if step 6 is deleted.
6. **Verification rejects a corrupt copy:** truncate the copied canonical store; assert the operation
   aborts before the commit point.

**Mutation checks are required, not optional.** This project has shipped vacuous tests twice — the
BM25 injection-surface test passed with quoting removed entirely, and the loose-end index-freshness
test passed with `updateStatus` deleted — and caught both only by running the mutation. Tests 3 and 5
in particular must be shown to fail when the behaviour they pin is removed.

**App:** build + eyeball. No unit tests exist for the app target, and this project's documented
smoke-launch renders no view body, so nothing in the modal, the panel, or the confirmation executes
under CI. Stated plainly rather than implied away.

## Human-verify carries

Need the built app installed at `/Applications` and the real store:

- The pane reads better: path legible and selectable, arrow reveals the right file, no jump when
  switching tabs.
- A **same-volume** move (e.g. to `~/Documents`) and a **cross-volume** move (external disk) both
  complete, relaunch, and show the same project count and loose-end count as before.
- The old folder is in the Bin, not gone.
- `pensieve list` from the CLI agrees with the app after the move — this is the cross-process
  proof that the defaults key is actually being read by a separate process.
- `tail -f ~/Library/Logs/Pensieve/sync.log` shows the agent resuming against the new location within
  ~300 s.
- A `git commit` **during** the move still shows up afterwards (the step-6 property, in situ).
- German in situ for the ~14 new keys.

## Out of scope

Per-file custom paths · custom Logs location · migrating the `SMAppService` plist (it references the
in-bundle helper, not the store) · security-scoped bookmarks · a CLI `relocate` command · cleaning up
the stale `.bak` files and retired `preferences.json` in the support directory (unrelated pre-existing
debris; mention, don't delete).

## Open risks

- **Cross-process defaults from a launchd context.** `PensieveDefaults.shared()` is already read
  cross-process for `llmProvider` and translation settings, so the mechanism is proven — but it is
  proven from a *CLI* context, not verified from the launchd-spawned helper specifically. The
  human-verify `sync.log` check above is what closes this, and it should be run before the branch is
  called done.
- **Free-space estimation** uses the measured directory size against
  `volumeAvailableCapacityForImportantUsage`. It cannot account for another process writing during the
  copy; a mid-copy `ENOSPC` is handled as an ordinary step-3 failure (clean up, abort, report) rather
  than predicted away.
