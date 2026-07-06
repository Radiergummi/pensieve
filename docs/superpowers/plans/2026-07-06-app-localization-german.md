# Pensieve.app Localization (String Catalog + German) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a German localization of all Pensieve.app UI chrome via a first-party Xcode String Catalog, with automatic English fallback.

**Architecture:** Add one `Localizable.xcstrings` to the app target; wire `project.yml` to ship `de`; make every chrome string extractable (`LocalizedStringKey` / `String(localized:)` / `LocalizedStringResource`); author impersonal/infinitive German for every key. Captured content (node names, quotes, descriptions, transcripts) is never localized.

**Tech Stack:** SwiftUI, Xcode 26.6 String Catalogs, XcodeGen 2.45.4, macOS 15 target.

## Global Constraints

- **Chrome only, never content.** Never route node `name`, loose-end `quote`, `description`, `event.summary`, `role`, or transcript text through the catalog. When a `Text` interpolates chrome + content, the content stays an argument (`%@`); only the surrounding frame is a translation key.
- **Base language English, target German (`de`).** English literal = the key = the base value. Missing `de` value → English fallback (never blank).
- **App target only.** Do NOT touch the `pensieve` CLI, and do NOT touch `Sources/PensieveApp/AppIntents/*` (Siri/Shortcuts phrases are a deferred follow-up).
- **Build & smoke commands** (never point at the live store):
  - `xcodegen generate`
  - `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build`
  - App: `./.build-xcode/Build/Products/Debug/Pensieve.app`; inner binary: `…/Pensieve.app/Contents/MacOS/Pensieve`
  - Forced-locale smoke launch (background, then `kill`), throwaway stores:
    ```bash
    PENSIEVE_DB=/tmp/l10n.sqlite PENSIEVE_CAPTURE_DB=/tmp/l10n-cap.sqlite \
      ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve -AppleLanguages '(de)' &
    sleep 3; screencapture -x -o /tmp/de.png; kill %1
    ```
- If a build dies with a SwiftSyntax/macro linker error, `rm -rf .build` and retry. First `xcodebuild` on a fresh machine needs the SPM macro fingerprints trusted (see CLAUDE.md).
- Work in an isolated git worktree (`git worktree add ../pensieve-l10n -b feat/app-localization-german`). Commit messages: use `git commit -F` (backticks in `-m` get shell-executed); keep the `Co-Authored-By:` + `Claude-Session:` trailers.

---

### Task 1: Wire the localization build and prove German ships (skeleton)

Prove the entire pipeline end-to-end with a single already-extractable string (`"Refresh"`, used by both the Go ▸ Refresh menu item and the menu-bar popover) **before** doing bulk work. If German doesn't render here, nothing else will.

**Files:**
- Modify: `project.yml` (options + settings + Info)
- Create: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Produces: a working `de` build pipeline + a catalog file that later tasks extend. No Swift symbols.

- [ ] **Step 1: Add development language + known regions to `project.yml` options**

In `project.yml`, change the `options:` block from:

```yaml
options:
  bundleIdPrefix: me.mazetti
  deploymentTarget:
    macOS: "15.0"
```

to:

```yaml
options:
  bundleIdPrefix: me.mazetti
  developmentLanguage: en
  knownRegions:
    - en
    - de
  deploymentTarget:
    macOS: "15.0"
```

- [ ] **Step 2: Force the bundle to advertise both localizations + keep string extraction on**

In `project.yml`, under `targets: Pensieve: info: properties:`, add `CFBundleLocalizations` (belt-and-suspenders alongside `knownRegions`):

```yaml
        CFBundleLocalizations:
          - en
          - de
```

And under `targets: Pensieve: settings: base:`, add:

```yaml
        SWIFT_EMIT_LOC_STRINGS: "YES"
```

- [ ] **Step 3: Create the catalog skeleton with one proven German string**

Create `Sources/PensieveApp/Localizable.xcstrings`:

```json
{
  "sourceLanguage" : "en",
  "strings" : {
    "Refresh" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Aktualisieren"
          }
        }
      }
    }
  },
  "version" : "1.0"
}
```

- [ ] **Step 4: Generate + build**

Run:
```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED. (If `xcodegen generate` errors on `knownRegions`, it is unsupported by this version — remove it and rely on `CFBundleLocalizations`; the Step 6 bundle check is the arbiter.)

- [ ] **Step 5: Verify German compiled into the bundle**

Run:
```bash
ls ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources | grep -E 'de.lproj|Localizable'
```
Expected: a `de.lproj` directory (containing a compiled `Localizable.strings`) is present — proof German ships, not just exists in source. If absent, the region wiring failed; fix Steps 1–2 before proceeding.

- [ ] **Step 6: Verify the German string renders at runtime**

Run the forced-`de` smoke launch (Global Constraints), then read the menu-bar/menu label. Simplest reliable check — the Go menu's Refresh item:
```bash
PENSIEVE_DB=/tmp/l10n.sqlite PENSIEVE_CAPTURE_DB=/tmp/l10n-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve -AppleLanguages '(de)' &
sleep 3; screencapture -x -o /tmp/de-skeleton.png; kill %1 2>/dev/null
```
Open `/tmp/de-skeleton.png` (Read tool) and confirm the menu-bar popover's **Refresh** button reads **Aktualisieren**. (Open the popover isn't scriptable here; if the popover isn't visible, instead grep the compiled strings: `plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep Aktualisieren` — a match proves the pipeline.)
Expected: "Aktualisieren" present.

- [ ] **Step 7: Commit**

```bash
git add project.yml Sources/PensieveApp/Localizable.xcstrings
git commit -F - <<'EOF'
feat(l10n): wire String Catalog + German region; prove pipeline (Refresh→Aktualisieren)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

### Task 2: Make every chrome string extractable (straggler fixes)

Convert user-facing strings that are currently plain `String` (verbatim, non-localizable) into extractable forms. No German yet — after this task the app still renders English, but every chrome string has become a catalog key. `.xcodeproj`/`.build-xcode` are gitignored, so only the Swift files change here.

**Files:**
- Modify: `Sources/PensieveApp/AppModel.swift:11-15`
- Modify: `Sources/PensieveApp/MenuBarView.swift:15-21` and `:87-93`
- Modify: `Sources/PensieveApp/SidebarView.swift:81-83`
- Modify: `Sources/PensieveApp/BriefingView.swift:61-66`
- Modify: `Sources/PensieveApp/DetailView.swift:122` and `:131-136`

**Interfaces:**
- Consumes: nothing new.
- Produces: `SmartListKind.title` still returns `String` (now localized); the two `section(_:)` helpers now take `LocalizedStringResource`; call sites are unchanged (string literals auto-convert). No signature change is visible outside each file.

- [ ] **Step 1: Localize `SmartListKind.title` (AppModel.swift)**

Replace the `title` computed property (lines 11–15):

```swift
  var title: String {
    switch self {
    case .whatsNext: return "What's Next"
    case .dormant: return "Dormant"
    case .recentlyActive: return "Recently Active"
    }
  }
```

with:

```swift
  var title: String {
    switch self {
    case .whatsNext: return String(localized: "What's Next")
    case .dormant: return String(localized: "Dormant")
    case .recentlyActive: return String(localized: "Recently Active")
    }
  }
```

(This localizes every use — sidebar rows and the ⌘K palette, which uses `kind.title` for both its match test and its display label, so search stays consistent.)

- [ ] **Step 2: Localize the menu-bar status label + statusLine (MenuBarView.swift)**

Replace the `label` computed property in the `MonitorSnapshot.Status` extension (lines 15–21):

```swift
  var label: String {
    switch self {
    case .active: return "Active"
    case .idle: return "Idle"
    case .notSetUp: return "Not set up"
    }
  }
```

with:

```swift
  var label: String {
    switch self {
    case .active: return String(localized: "Active")
    case .idle: return String(localized: "Idle")
    case .notSetUp: return String(localized: "Not set up")
    }
  }
```

Then replace `statusLine` (lines 87–93):

```swift
  private var statusLine: String {
    var s = model.snapshot.status.label
    if let last = model.snapshot.lastCaptureAt {
      s += " · captured \(Self.relativeAge(last))"
    }
    return s
  }
```

with:

```swift
  private var statusLine: String {
    var s = model.snapshot.status.label
    if let last = model.snapshot.lastCaptureAt {
      s += String(localized: " · captured \(Self.relativeAge(last))")
    }
    return s
  }
```

- [ ] **Step 3: Localize the sidebar status footer (SidebarView.swift)**

Replace `StatusFooter.label` (lines 81–83):

```swift
  private var label: String {
    switch snapshot.status { case .active: return "capturing"; case .idle: return "idle"; case .notSetUp: return "not set up" }
  }
```

with:

```swift
  private var label: String {
    switch snapshot.status {
    case .active: return String(localized: "capturing")
    case .idle: return String(localized: "idle")
    case .notSetUp: return String(localized: "not set up")
    }
  }
```

- [ ] **Step 4: Make the BriefingView `section(_:)` helper localize its title**

Replace the helper (lines 61–66):

```swift
  @ViewBuilder private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
      content()
    }
  }
```

with:

```swift
  @ViewBuilder private func section(_ title: LocalizedStringResource, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(String(localized: title).uppercased()).font(.caption).bold().foregroundStyle(.secondary)
      content()
    }
  }
```

Call sites `section("Moved")` / `section("Quiet")` are unchanged — the literals auto-convert to `LocalizedStringResource` and are extracted as keys `"Moved"` / `"Quiet"`.

- [ ] **Step 5: Make the DetailView `section(_:)` helper localize its title + fix the "captured" fallback**

Replace the DetailView `section` helper (lines 131–136) with the identical `LocalizedStringResource` version:

```swift
  @ViewBuilder private func section(_ title: LocalizedStringResource, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(String(localized: title).uppercased()).font(.caption).bold().foregroundStyle(.secondary)
      content()
    }
  }
```

Then fix the bare `"captured"` fallback on line 122. Replace:

```swift
          Text("\(view.looseEnd.role.isEmpty ? "captured" : view.looseEnd.role) · \(view.occurredAt, format: .dateTime.year().month().day()) · \(view.ageDays)d ago")
```

with:

```swift
          Text("\(view.looseEnd.role.isEmpty ? String(localized: "captured") : view.looseEnd.role) · \(view.occurredAt, format: .dateTime.year().month().day()) · \(view.ageDays)d ago")
```

(Only the `"captured"` chrome word gets a key; the surrounding frame mixes content — `role` — and is deliberately left English-fallback.)

- [ ] **Step 6: Build to confirm it still compiles**

Run:
```bash
xcodegen generate
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Expected: BUILD SUCCEEDED. (Display is still English — the catalog has German only for `"Refresh"` so far.)

- [ ] **Step 7: Commit**

```bash
git add Sources/PensieveApp/AppModel.swift Sources/PensieveApp/MenuBarView.swift Sources/PensieveApp/SidebarView.swift Sources/PensieveApp/BriefingView.swift Sources/PensieveApp/DetailView.swift
git commit -F - <<'EOF'
refactor(l10n): make all chrome strings extractable (String → localized)

Localizes SmartListKind.title, menu-bar/sidebar status labels, the two
section() helpers (LocalizedStringResource), and the "captured" fallback.
No behavior change; display still English pending the German pass.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

### Task 3: Author German for every key and verify

Fill the catalog with German for all keys, then verify German renders and English is intact.

**Files:**
- Modify: `Sources/PensieveApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: the extractable keys produced by Tasks 1–2.
- Produces: a complete German localization. No Swift symbols.

- [ ] **Step 1: (Authoritative-key aid) Build, then read any auto-populated keys**

Run a build, then inspect the catalog — Xcode string extraction may write newly discovered keys into the source `.xcstrings`:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
```
Read `Sources/PensieveApp/Localizable.xcstrings`. If extraction populated keys, those are authoritative — translate exactly those (especially the interpolated `%lld` / `%@` keys, whose exact spelling matters). If it did NOT populate, author the keys from the table in Step 2 verbatim; the Step 3 forced-`de` screenshots are the backstop that catches any key mismatch (an English string where German was expected = wrong key).

- [ ] **Step 2: Write the full German catalog**

Overwrite `Sources/PensieveApp/Localizable.xcstrings` with every key below. Each entry has the shape:

```json
    "KEY" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "GERMAN" } }
      }
    }
```

Translation table (impersonal/infinitive, Apple German conventions). **Omit** `"Briefing"` and `"Pensieve"` — proper names, left as the English fallback.

Standalone labels / titles / empty-states / menu items:
| Key | German |
|---|---|
| `Smart Lists` | `Intelligente Listen` |
| `Projects` | `Projekte` |
| `What's Next` | `Als Nächstes` |
| `Dormant` | `Ruhend` |
| `Recently Active` | `Kürzlich aktiv` |
| `Moved` | `Bewegt` |
| `Quiet` | `Ruhig` |
| `Last Work Done` | `Zuletzt erledigt` |
| `Loose Ends` | `Lose Enden` |
| `Recent Activity` | `Letzte Aktivität` |
| `None open.` | `Keine offen.` |
| `No captured activity.` | `Keine erfasste Aktivität.` |
| `No captured activity yet.` | `Noch keine erfasste Aktivität.` |
| `Nothing here` | `Nichts hier` |
| `Nothing queued` | `Nichts in Warteschlange` |
| `Select a project` | `Projekt auswählen` |
| `Select a loose end` | `Loses Ende auswählen` |
| `Pick a loose end to see its source.` | `Ein loses Ende auswählen, um die Quelle zu sehen.` |
| `PROVENANCE` | `HERKUNFT` |
| `Surrounding context unavailable (transcript changed or removed).` | `Umgebender Kontext nicht verfügbar (Transkript geändert oder entfernt).` |
| `Project unavailable` | `Projekt nicht verfügbar` |
| `No project` | `Kein Projekt` |
| `Open in New Window` | `In neuem Fenster öffnen` |
| `Go` | `Gehe zu` |
| `Quick Jump…` | `Schnellsprung…` |
| `Refresh` | `Aktualisieren` |
| `Inspector` | `Inspektor` |
| `Recall` | `Rückblick` |
| `Open Pensieve` | `Pensieve öffnen` |
| `Quit` | `Beenden` |
| `Jump to…` | `Wechseln zu…` |
| `Active` | `Aktiv` |
| `Idle` | `Inaktiv` |
| `Not set up` | `Nicht eingerichtet` |
| `capturing` | `erfasst` |
| `idle` | `inaktiv` |
| `not set up` | `nicht eingerichtet` |
| `captured` | `erfasst` |

Interpolated frames (numbers/dates stay as `%lld`/`%@` arguments — verify exact key spelling against Step 1):
| Key | German |
|---|---|
| `Since %@` | `Seit %@` |
| `%lld since last visit` | `%lld seit letztem Besuch` |
| `dormant %lldd` | `ruhend %lldT` |
| `%lld open` | `%lld offen` |
| `%lld open · %lldd dormant` | `%lld offen · %lldT ruhend` |
| ` · captured %@` | ` · erfasst %@` |

**Do NOT add** keys that mix content (leave them English-fallback): `%@ · %@` (kind·state, DetailView) and `%@ · %@ · %lldd ago` (loose-end line, DetailView).

The resulting file is one JSON object: `"sourceLanguage": "en"`, a `"strings"` object with all the above keys, `"version": "1.0"`. Keep the `"Refresh"` entry from Task 1 (same key/value).

- [ ] **Step 3: Build + verify German renders**

Run:
```bash
xcodegen generate && xcodebuild -project Pensieve.xcodeproj -scheme Pensieve -configuration Debug -derivedDataPath ./.build-xcode build
PENSIEVE_DB=/tmp/l10n.sqlite PENSIEVE_CAPTURE_DB=/tmp/l10n-cap.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve -AppleLanguages '(de)' &
sleep 3; screencapture -x -o /tmp/de-full.png; kill %1 2>/dev/null
```
Read `/tmp/de-full.png`. Expected: sidebar reads **Intelligente Listen / Projekte / Als Nächstes / Ruhend / Kürzlich aktiv**; the empty detail reads **Projekt auswählen**; the sidebar footer shows a German status word. Also confirm the compiled table:
```bash
plutil -p ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Resources/de.lproj/Localizable.strings | grep -E 'Projekte|Als Nächstes|Lose Enden'
```
Expected: matches present. Any expected-German string that renders English = a key mismatch; fix the key in the catalog against Step 1's authoritative set and rebuild.

- [ ] **Step 4: Verify English is intact**

Run the same launch with `-AppleLanguages '(en)'`, screenshot `/tmp/en-full.png`, and confirm the base UI is unchanged English (no blanks, no German leakage).

- [ ] **Step 5: Layout / truncation eyeball**

In `/tmp/de-full.png`, check the sidebar rows, toolbar, and menu items for truncation or clipping (German runs longer). If any label clips, apply a view-local fix (`.lineLimit(1)` + `.minimumScaleFactor(0.8)`, or widen the column's `ideal`) in the offending view only — chrome layout only, no logic change. Rebuild + re-screenshot to confirm.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveApp/Localizable.xcstrings Sources/PensieveApp/*.swift
git commit -F - <<'EOF'
feat(l10n): German translations for all app UI chrome

Full de localization of the SwiftUI app (sidebar, briefing, detail,
menu-bar, palette, inspector, windows, menus). Content never localized;
English fallback preserved. Verified via forced-locale launch (de/en).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GsAu7rTTdD77k3xZHZrhm4
EOF
```

---

## Human-verify carry (the user's to run)

Open the built app under the **real** macOS German system language (System Settings ▸ Language & Region, or the app added to the per-app language list) and sanity-check translation tone/accuracy in situ — especially the menu-bar popover and the ⌘K palette, which are awkward to screenshot headlessly. Native-speaker review of the Step-2 table wording (e.g. "Bewegt"/"Ruhig" for the Moved/Quiet sections, "Rückblick" for the Recall window) is expected; adjust any that read oddly.

## Self-review notes (author)

- **Spec coverage:** catalog + wiring (Task 1) ✓; audit/straggler fixes (Task 2) ✓; German translation (Task 3) ✓; verification incl. `de.lproj` bundle check + forced-locale + layout (Task 1 Step 5, Task 3 Steps 3–5) ✓; chrome-only invariant (Global Constraints + explicit "do NOT add content-mixed keys") ✓; out-of-scope CLI/AppIntents (Global Constraints) ✓.
- **Deferred by design (English fallback, documented):** the two content-mixed interpolation frames in DetailView; the `"Briefing"`/`"Pensieve"` proper names.
