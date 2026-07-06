# Pensieve.app — Localization (String Catalog + German)

**Date:** 2026-07-06
**Status:** Approved (brainstormed) — ready for `writing-plans`.
**Scope of this spec:** adopt a first-party **String Catalog** for the SwiftUI app and ship a
**German** localization of all UI chrome. Sequenced **before three-pane slice 4** (in-app organizing
writes) so German is in place as slice 4 adds strings; slice 4 already commits to
`LocalizedStringKey` for its own strings, so it will be catalog-ready.

## Why

The three-pane design (`2026-07-05-pensieve-app-three-pane-design.md`) mandated
`LocalizedStringKey` / `String(localized:)` "from day one so chrome is catalog-ready," with actual
localization called out as **a separate ledger item**. This is that item. The user is a native
German speaker; a German UI is genuine value, and doing it now — while the app surface is still
small (~30 literal-string call sites, no `.xcstrings` yet, only 2 `String(localized:)` uses) — is
far cheaper than after the app has grown.

## Principles (inherited, non-negotiable)

- **Platform primitives first.** Use Xcode's **String Catalog** (`.xcstrings`, Xcode 15+), with
  compile-time string extraction. No third-party i18n library, no hand-maintained `.strings`, no
  `genstrings`.
- **Chrome only, never content.** Localize UI chrome exclusively. **Never** localize node names,
  loose-end quotes, descriptions, transcript text, or any captured content — that is user data.
  This is a hard invariant, restated from the MVP/three-pane specs.
- **Graceful fallback.** Any key lacking a German value renders the English base automatically.
  This slice, and every future string, degrades gracefully — nothing is ever blank.

## Architecture & wiring

### The catalog
- **One `Localizable.xcstrings`** added under `Sources/PensieveApp/`. XcodeGen's existing
  `sources: [Sources/PensieveApp]` glob picks it up and Xcode treats `.xcstrings` as a resource in
  the app bundle — no per-file build-phase config needed. (Verify it lands in the built
  `Pensieve.app/Contents/Resources/` as a compiled `.lproj`/`.strings` set.)
- **Base development language: English.** The literal English string is the key *and* the base
  value.
- **Target language: German (`de`).** Added inside the catalog.

### `project.yml` (source of truth; regenerated via `xcodegen generate`)
Nail down in the plan, verified at build time:
- **Known regions / shipped localizations must include `de`.** A String Catalog declares its
  languages, but the *bundle* must be told to ship German. Set this via the project's
  `knownRegions` (XcodeGen `options.knownRegions: [en, de]` or equivalent) and/or
  `CFBundleLocalizations = [en, de]` in the target Info block. The plan picks whichever the SDK
  honors and the build/verification confirms German actually ships (Section "Verification").
- **Keep compiler string extraction on** (`SWIFT_EMIT_LOC_STRINGS = YES`, the default for String
  Catalogs) so every `LocalizedStringKey` / `String(localized:)` is auto-extracted at build time.
- **Development region** stays `en`.

## The work — three passes

### Pass 1 — Audit for stragglers (make everything extractable)
Only strings typed as `LocalizedStringKey` (e.g. `Text("Rename")`, `Button("Move to…")`,
`.navigationTitle(...)`) or explicit `String(localized:)` are extracted. A user-facing string passed
as a plain `String` to a non-localized initializer is silently **not** localized.

- Sweep every file in `Sources/PensieveApp/` for user-facing chrome passed as plain `String`
  (interpolated strings, strings built then handed to a `String`-typed parameter, accessibility
  labels, window/menu titles, `ContentUnavailableView` text, confirmation/alert copy).
- Convert each to `LocalizedStringKey` or `String(localized:)` as the call site requires.
- **The catalog is the audit:** after Pass 2's build, any chrome string absent from the catalog is
  one we typed wrong — fix and rebuild.
- **Do not touch** any string that renders captured content (node `name`, loose-end `quote`,
  `description`, transcript lines). Where a view interpolates chrome + content (e.g.
  `"\(count) loose ends"`), localize only the chrome frame via a format string with the content as
  an argument; never route the content itself through the catalog.

### Pass 2 — Adopt the catalog
- Add `Localizable.xcstrings` (with `en` base + `de`) to `Sources/PensieveApp/`.
- `xcodegen generate` → `xcodebuild` → Xcode extracts all keys; the catalog's English column fills
  from the base values.
- Confirm the extracted key set matches the audited call sites (drives Pass 1 fixes).

### Pass 3 — Translate to German
- Draft **impersonal / infinitive** German for every key — Apple's own macOS German convention:
  infinitive for actions ("Umbenennen", "Verschieben nach…", "Zusammenführen", "Typ ändern"),
  nominal for labels ("Lose Enden", "Letzte Aktivität"). Author drafts; the native-speaker user
  reviews and corrects in a pass. Set each string's catalog state appropriately
  (translated / needs-review).
- Handle **plurals** via the catalog's variations where a count-bearing string exists (German
  plural rules differ from English), rather than string concatenation.

## Verification

The app has no unit tests (Xcode app target), so verify by build + forced-locale launch:

1. `xcodegen generate` && `xcodebuild -project Pensieve.xcodeproj -scheme Pensieve
   -configuration Debug -derivedDataPath ./.build-xcode build`.
2. **German render:** launch the inner binary
   (`./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/MacOS/Pensieve`) with
   `-AppleLanguages "(de)"`, forwarding throwaway `PENSIEVE_DB` / `PENSIEVE_CAPTURE_DB` (never the
   live store), non-blocking (background + `kill`). `screencapture -x -o <png>` the window and
   confirm German chrome renders across the main views (sidebar, briefing, detail, menu-bar
   popover); confirm any still-untranslated key falls back to English (not blank).
3. **English intact:** repeat with `-AppleLanguages "(en)"`; confirm the base is unchanged.
4. **Bundle check:** confirm `Pensieve.app` contains a `de.lproj` (or the compiled catalog for
   `de`) — proves German actually ships, not just exists in source.
5. Manual eyeball of the key views in German for truncation / layout regressions (German runs
   longer than English; check the sidebar and toolbar especially).

Human-verify carry (the user's to run): open the built app under the real macOS German system
language and sanity-check the tone/accuracy of the translations in situ.

## Out of scope (this slice)

- **CLI (`pensieve`) output** — developer-facing, single user; low value. English only.
- **App Intents / Siri / Shortcuts phrases** and intent/entity titles — a distinct mechanism
  (AppShortcuts phrase localization) plus Siri/Shortcuts human-verify in German. **Deferred to a
  noted follow-up** on the backlog.
- **Captured content of any kind** — a permanent invariant, never localized.
- **Additional languages** beyond German — the catalog makes adding more trivial later; not now.

## Risks / notes

- **German string length** can break tight layouts (toolbars, sidebar labels). Mitigated by the
  Verification eyeball pass (step 5); fixes are view-local (`.lineLimit`, `.minimumScaleFactor`,
  layout breathing room) and stay chrome-only.
- **Missed stragglers** — a plain-`String` chrome value slips the audit. Mitigated because the
  catalog surfaces exactly the extracted set; a diff against the audited call sites catches gaps.
- **XcodeGen resource handling** — if `.xcstrings` isn't auto-bundled, the plan adds an explicit
  resource entry; Section-Verification step 4 (the `de.lproj` bundle check) is the backstop that
  proves it worked.

## Process

Mechanical adoption + translation sweep, not risky logic → **a single spec review**, then
`writing-plans` → subagent-driven execution (implementer + task review = Sonnet; final whole-branch
review = Opus), in an isolated worktree, per the loop in `CONTINUE.md`. Slice 4 (in-app organizing
writes) is scheduled **after** this slice; its design is already brainstormed (context menus +
inline rename; PensieveKit cycle guard on `nest`; `group()` self-cycle fix; all five ops incl.
merge with confirmation) and will get its own spec then.
