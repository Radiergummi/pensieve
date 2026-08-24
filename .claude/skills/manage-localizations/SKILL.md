---
name: manage-localizations
description: Use when adding, changing, renaming or deleting any user-facing string in Sources/PensieveApp or Sources/PensieveWidget — a new Text/Button/Label literal, reworded copy, a removed view, a missing German translation, an English string showing up under a German locale, or adding a new language. Covers the xcstrings tool, Localizable.xcstrings, and project.yml's language lists.
---

# Managing the String Catalogs

Both catalogs are hand-authored. `SWIFT_EMIT_LOC_STRINGS` and
`STRING_CATALOG_GENERATE_SYMBOLS` are **off** on both targets (deliberately — see the
comments in `project.yml`), so Xcode never extracts a key and nothing in the build
maintains these files. Every key gets there because someone put it there.

**Never edit a `.xcstrings` with `sed`, or by hand-aiming an Edit at 83 KB of JSON.**
That is what this tool exists to replace. A hand edit can duplicate a key — JSON keeps
the last of the pair, so the other copy is edited forever after and rendered nowhere.

```bash
make xcstrings          # builds ./.build/xcstrings (~2 s)
./.build/xcstrings      # prints usage
```

## The rule that makes this fiddly

**A catalog key must match its Swift literal character-for-character**, or German
silently falls back to English. Nothing warns you: not the compiler, not `xcodebuild`,
and not testing in English. The widget's gallery description shipped English-only for
exactly this reason.

So: **change the Swift literal and the catalog key in the same change, always.**
`xcstrings rename` is for when the copy changes; `add`/`remove` for when a string
appears or goes away.

## Which catalog

| The literal lives in | Use |
|---|---|
| `Sources/PensieveApp/**` | `--catalog app` |
| `Sources/PensieveWidget/**` | `--catalog widget` |
| `Sources/PensieveKit/**` | the catalog of **whichever target renders it** — usually `app` |

`--catalog` takes a path or any unique part of one. PensieveKit has no catalog of its
own: it supplies keys (like `NodeContext.displayKey`) that the app and widget render
through a runtime lookup, so its strings belong to the catalog of the target that shows
them. Put a key in the wrong catalog and `CatalogCoverageTests` reports it as dead.

## The four edits

```bash
# A new string. Every declared language must get a translation, or it refuses.
./.build/xcstrings add --catalog app --key "Reindex now" --translation de="Jetzt neu indizieren"

# Wording you have not checked — lands as needs_review instead of translated.
./.build/xcstrings add --catalog app --key "Reindex now" --draft de="Jetzt neu indizieren"

# Change an existing translation.
./.build/xcstrings set --catalog app --key "Reindex now" --translation de="Neu indizieren"

# The English copy changed. Translations come along; edit the Swift literal to match.
./.build/xcstrings rename --catalog app --from "Reindex now" --to "Reindex now…"

# The view is gone.
./.build/xcstrings remove --catalog app --key "Reindex now"
```

`--comment "<text>"` on `add` records why a string is worded the way it is. Worth it
whenever the German involved a judgement call — see the `Briefing` entry, which explains
in the file why it stays an English loanword.

## Verify — every time

```bash
./.build/xcstrings audit && make test FILTER=Catalog
```

`audit` exits non-zero on an untranslated language, a duplicate key, or a file that has
drifted out of canonical form. The tests are the real gate, and there are five:

- **`everyRenderedLiteralHasACatalogKey`** — a literal at a localizing call site with no
  key. Renders English under every locale.
- **`everyCatalogKeyIsRenderedBySomeLiteral`** — a key no literal produces. Dead weight
  that makes the catalog look like it covers more than it does.
- **`everyDeclaredLanguageTranslatesEveryKey`** — a declared language with nothing to
  render.
- **`catalogHasNoDuplicateKeys`** — the failure a hand edit causes and nothing else sees.
- **`projectDeclaresTheSameLanguagesEverywhere`** — `project.yml`'s three language lists
  disagreeing.

If a change touched the app target, finish with `make test` — `CatalogCoverageTests`
scans the app and widget sources, so an unrelated cached green is possible otherwise.

## Strings that are not translated

Two legitimate cases, both spelled in the file rather than in a test allowlist:

- **No copy to translate** — punctuation, a bare interpolation (`·`, `%@`). The entry
  carries `"shouldTranslate": false` and no localizations. The tool leaves these alone;
  set it by hand on the entry if a new one appears.
- **The same word in every language** — `Briefing` is an established German loanword. It
  gets a real key with the loanword as its German value, plus a `comment` saying why.
  Do **not** reach for a test allowlist: that makes the string invisible to the checks
  forever, which is how the topmost sidebar row stopped being covered once already.

**Captured content is never localized.** Node names, quotes, loose-end text, transcripts,
event summaries — all of it stays as captured. Only chrome is translated.

## German conventions already in the catalog

Match these; do not invent a second word for a concept that already has one.

| English | German |
|---|---|
| Project | Projekt |
| Strand | Strang |
| Node | Knoten |
| Loose end | loses Ende / lose Enden |
| Recall | Rückblick |
| Archive (verb) | Archivieren |
| Unarchive | Wiederherstellen |
| Briefing | Briefing (loanword, deliberate) |

Sentence-style copy uses „German quotation marks“, and `…` is a real ellipsis character
in both languages. Menu items and buttons that open something end in `…` in German too.

## Adding a language

```bash
./.build/xcstrings add-language fr
```

This writes `fr` into all three of `project.yml`'s language lists (`knownRegions` plus
one `CFBundleLocalizations` per bundled target — a language missing from the latter is
compiled and then never selected at runtime), then seeds every translatable entry in
every catalog with `state: "new"` and the English text as a placeholder.

**The suite will be red until every seeded string is translated.** That is intended:
`new` is xcstrings' word for untranslated, and a green suite over an untranslated
language is the failure mode this whole setup exists to prevent. Work through it with
`./.build/xcstrings audit` for the count, then `set --translation fr=…` per key, or
`--draft fr=…` for a pass that still needs checking. Then `make generate`, since the
`.xcodeproj` carries `knownRegions`.

Nothing in the tool or the tests names a language. `knownRegions` is the authority.

## When something refuses

| Message | What to do |
|---|---|
| `no translation given for de` | Pass `--translation de=…` (or `--draft de=…`). `add` will not create a half-translated key. |
| `contains N duplicate key(s)` | Delete the copy you do not want **by hand** first. The tool refuses rather than rewrite the file, because parsing already discarded one of the two. |
| `is already in Localizable.xcstrings` | Use `set` to change translations, or `rename` if the copy changed. |
| `--catalog 'x' is ambiguous` | Say `app` or `widget`. |
| `is a plural entry` | Plural `variations` can't be set from the command line. Edit that block by hand, then `./.build/xcstrings fmt`. |
| `not in canonical form` | `./.build/xcstrings fmt`. Only a hand edit or an Xcode write causes this. |

## Canonical form, and Xcode

Every catalog is kept sorted, with an explicit unit for every declared language, at two-
space indent with `"key" : value` spacing and no trailing newline. Mutations
re-canonicalize automatically, so `fmt` is only needed after something *else* wrote the
file. If Xcode ever reformats a catalog, run `fmt` and check the diff is formatting only.

A handful of keys are **identifiers rather than English text** — `Loose end done` renders
as "Done". `rename` detects this and leaves the English value alone, saying so. If you
want the English to change too, pass `--translation en=…`.

## Where the code is

- `Tools/xcstrings/` — the tool. `make xcstrings`.
- `Tests/PensieveKitTests/LocalizationRules.swift` — reading `project.yml`'s language
  lists, and counting keys as the file spells them. **Compiled into both the tool and the
  test target** (the Makefile names it on the tool's `swiftc` line), so there is one
  implementation of each rule rather than two that drift.
- `Tests/PensieveKitTests/CatalogCoverageTests.swift` — key ↔ literal agreement.
- `Tests/PensieveKitTests/CatalogIntegrityTests.swift` — duplicates, language
  completeness, `project.yml` agreement.
