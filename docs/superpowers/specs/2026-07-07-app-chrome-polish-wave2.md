# App chrome polish — wave 2 (refinements from dogfooding) — spec + plan

Follow-up to `2026-07-07-app-chrome-polish-batch.md` after the user eyeballed the built app. Four
refinements, same branch `feat/app-chrome-polish`, app-target only **except** one new SPM package
(MarkdownUI) added to the app target via `project.yml`. No PensieveKit changes.

Verification unchanged: `xcodegen generate && xcodebuild … build` → BUILD SUCCEEDED + non-blocking
smoke-launch of the inner binary. Visuals are human-verify carries.

Execution order: **T5 typography → T6 toolbar → T7 inspector markdown → T8 modal pickers** (biggest last).

---

## T5 — Typography hierarchy + timeline balance

**Problem.** Section eyebrows (`ZULETZT ERLEDIGT`, `LOSE ENDEN`, `LETZTE AKTIVITÄT`, `HERKUNFT`) are
`.caption` (~10pt) — far too small against the new 14pt body; the screen has ~6 near-caption
variants with no clear scale. The activity timeline rail is unbalanced (oversized dot, a connector
stub dangling below the last row, misaligned time/label).

**Design — one shared type scale in `ProseStyle.swift`:**

```swift
extension View {
  /// Section eyebrow (uppercased, tracked). One consistent treatment for every content section
  /// header (Detail's Last Work Done / Loose Ends / Recent Activity, Inspector's Provenance,
  /// Briefing's Moved / Quiet).
  func sectionHeader() -> some View {
    self.font(.system(size: 13, weight: .semibold))
      .textCase(.uppercase)
      .tracking(0.6)
      .foregroundStyle(.secondary)
  }
  /// Small metadata (timestamps, roles, source labels, dormancy). One caption treatment.
  func metaText() -> some View {
    self.font(.footnote).foregroundStyle(.secondary)
  }
}
```

**Apply:**
- `DetailView.section(_:content:)` and `BriefingView.section(_:content:)`: replace the inline
  `Text(String(localized: title).uppercased()).font(.caption).bold().foregroundStyle(.secondary)`
  with `Text(title).sectionHeader()`. (Keep passing the `LocalizedStringResource`; drop the manual
  `.uppercased()` — `.textCase(.uppercase)` handles it, so localized German casing stays correct.)
- `InspectorView`: the `Text("PROVENANCE")…` header → `Text("Provenance").sectionHeader()` (add
  `"Provenance"` key; German `"Herkunft"`). The loose-end title below stays `.headline`.
- Timeline day header (`ActivityTimeline`): `Text(day, …).font(.caption).bold()` →
  `.font(.subheadline).fontWeight(.semibold).foregroundStyle(.primary)` (a clear day divider).
- Loose-end meta line + timeline source label/time: route through `.metaText()` where they are
  currently ad-hoc `.caption`/`.caption2`. (Timeline time stays `.monospacedDigit()`.)

**Timeline rebalance (`ActivityTimeline` / `TimelineRow`):** make the rail HIG-clean —
- Smaller dot (8pt), vertically aligned to the first text line's center.
- The connector line draws **between** rows only, never a stub after the last event of a day. Do
  this by having `ActivityTimeline` enumerate each day's events with an `isLast` flag and pass it to
  `TimelineRow(event:isLast:)`; when `isLast`, omit the trailing `Rectangle` connector.
- Row layout: line 1 = source icon + source label + time (`.metaText()`); line 2 = summary
  (`.prose()`). Row vertical spacing 12; dot-to-content spacing 10.

Concrete `ActivityTimeline` body:
```swift
    VStack(alignment: .leading, spacing: 16) {
      ForEach(days, id: \.self) { day in
        let items = (groups[day] ?? []).sorted { $0.occurredAt > $1.occurredAt }
        VStack(alignment: .leading, spacing: 12) {
          Text(day, format: .dateTime.weekday(.wide).month().day())
            .font(.subheadline).fontWeight(.semibold).foregroundStyle(.primary)
          ForEach(Array(items.enumerated()), id: \.element.id) { idx, event in
            TimelineRow(event: event, isLast: idx == items.count - 1)
          }
        }
      }
    }
```
`TimelineRow` gains `let isLast: Bool`; the rail VStack becomes:
```swift
      VStack(spacing: 0) {
        Circle().fill(color).frame(width: 8, height: 8).padding(.top, 2)
        if !isLast { Rectangle().fill(.quaternary).frame(width: 1.5).frame(maxHeight: .infinity) }
      }
      .frame(width: 8)
```

New strings: `"Provenance"` (de `Herkunft`) — replaces the raw `"PROVENANCE"` literal.

---

## T6 — Toolbar: trim + place per the split view

**Problem.** Seven toolbar buttons; the user wants only three, placed to match the split view:
`| [>] [+] |  (center: none)  | [⟳] [<] |` — left column gets a **sidebar-collapse toggle** + **New**;
detail column gets **Refresh** + **Inspector toggle**. Edit/Move/Merge/Delete leave the toolbar
(they remain in the right-click `NodeContextMenu`).

**Design (`RootView`):**
- Add `@State private var columns = NavigationSplitViewVisibility.all` and pass it to
  `NavigationSplitView(columnVisibility: $columns)`.
- Replace the whole `.toolbar { … }` with placement-anchored groups:

```swift
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button {
          withAnimation { columns = (columns == .detailOnly ? .all : .detailOnly) }
        } label: { Image(systemName: "sidebar.left") }
          .help("Toggle Sidebar")
        Button { model.presentNewNode(under: nil) } label: { Image(systemName: "plus") }
          .help("New Node")
      }
      ToolbarItemGroup(placement: .primaryAction) {
        Button { Task { await model.refreshNow() } } label: { Image(systemName: "arrow.clockwise") }
          .help("Refresh")
        Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
          .help("Inspector")
      }
    }
```
(Refresh before Inspector so the trailing order reads `[⟳] [<]`.) Keep every other RootView modifier
(the four `.sheet`/`.confirmationDialog`, `.inspector`, `.onChange`) unchanged. The `selectedNode`/
`canDeleteSelection` helpers added in T2 are now unused → **remove them** (orphan cleanup).

New strings: `"Toggle Sidebar"` (de `Seitenleiste ein-/ausblenden`). `"New Node"`, `"Refresh"`,
`"Inspector"` already exist.

---

## T7 — Inspector: render Markdown + un-faint role labels

**Problem.** Transcript messages render raw Markdown as plain text (`**bold**`, `` `code` ``); role
labels (`assistant`/`user`) are `.caption2`/`.tertiary` — nearly invisible.

**Design.** Add the **MarkdownUI** SPM package to the app target and render message bodies with it.

`project.yml` — add under `packages:` and the target's `dependencies:`:
```yaml
packages:
  PensieveKit:
    path: .
  MarkdownUI:
    url: https://github.com/gonzalezreal/swift-markdown-ui
    from: "2.4.1"
```
```yaml
    dependencies:
      - package: PensieveKit
        product: PensieveKit
      - package: MarkdownUI
        product: MarkdownUI
```

`InspectorView.messageRow`:
```swift
  @ViewBuilder private func messageRow(_ msg: ProvenanceMessage) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(msg.role).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
      Markdown(msg.text)
        .markdownTextStyle { FontSize(14) }
        .padding(.leading, msg.isCited ? 10 : 0)
        .overlay(alignment: .leading) {
          if msg.isCited { Rectangle().fill(.orange).frame(width: 3) }
        }
    }
    .opacity(msg.isUserPrompt ? 1 : 0.7)   // was 0.55 — lift so dimmed context stays readable
    .frame(maxWidth: .infinity, alignment: .leading)
  }
```
`import MarkdownUI` at the top. The honest-fallback quote (`le.quote`) stays plain `Text().italic()`
(it is a verbatim citation, not Markdown). Role label bumped `.caption2`→`.caption` + `.semibold` +
`.secondary` (from `.tertiary`); dim opacity 0.55→0.7.

No new user-facing strings (`msg.role` is captured content, not localized).

---

## T8 — Modal: Reminders-parity round toggles + anchored picker popovers

**Problem.** The current Symbol/Emoji **text buttons** don't match Reminders. Reference screenshots
show, under a **"Symbol:"** label, **two round toggle buttons**: an **emoji** button (light-tint
circle showing the current emoji, else a smiley) and a **symbol** button (filled-accent circle
showing the current SF symbol in white). The active mode's button is filled accent; the other is a
light tint. Each opens an **anchored `.popover`** with a search field + grid (emoji: grid + category
tabs; symbol: round-tinted glyph grid, selected one ringed).

**Design.** New file `Sources/PensieveApp/IconPicker.swift` holding the catalog + the two popovers +
the toggle row; `NodeEditor`'s right zone becomes just the preview circle + this toggle row.

**Public-API note (design decision):** there is no public *anchored system emoji panel* (Reminders
uses an Apple-internal one). We reproduce the look with a SwiftUI `.popover`. Emoji **names for
search** come from the Foundation `.toUnicodeName` `StringTransform` — no bundled data file.

### `IconPicker.swift`

Emoji catalog by Unicode ranges (compact, generated at load — no giant literals):
```swift
import SwiftUI

/// Emoji grouped into the picker's bottom-tab categories, generated from Unicode scalar ranges and
/// filtered to single-scalar emoji-presentation characters (skips ZWJ sequences — a solid, common set).
enum EmojiCatalog {
  struct Category: Identifiable { let id: String; let symbol: String; let emoji: [String] }

  private static func build(_ ranges: [ClosedRange<UInt32>]) -> [String] {
    var out: [String] = []
    for r in ranges {
      for v in r {
        guard let scalar = Unicode.Scalar(v) else { continue }
        let props = scalar.properties
        if props.isEmoji && props.isEmojiPresentation { out.append(String(scalar)) }
      }
    }
    return out
  }

  static let categories: [Category] = [
    Category(id: "smileys", symbol: "face.smiling", emoji: build([0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97A])),
    Category(id: "people",  symbol: "person",       emoji: build([0x1F464...0x1F487, 0x1F9D0...0x1F9DF])),
    Category(id: "nature",  symbol: "leaf",          emoji: build([0x1F400...0x1F43E, 0x1F980...0x1F9AE, 0x1F330...0x1F344])),
    Category(id: "food",    symbol: "fork.knife",    emoji: build([0x1F345...0x1F37F, 0x1F950...0x1F96F])),
    Category(id: "activity",symbol: "soccerball",    emoji: build([0x1F3A0...0x1F3CA, 0x1F93C...0x1F93E])),
    Category(id: "travel",  symbol: "car",           emoji: build([0x1F680...0x1F6C5, 0x1F3E0...0x1F3F0])),
    Category(id: "objects", symbol: "lightbulb",     emoji: build([0x1F4A1...0x1F4FF, 0x1F526...0x1F52F])),
    Category(id: "symbols", symbol: "heart",         emoji: build([0x2600...0x26FF, 0x1F532...0x1F53D])),
  ]

  /// A lowercase Unicode name for search, e.g. "😀" → "grinning face". Uses the system transform.
  static func name(of emoji: String) -> String {
    let t = emoji.applyingTransform(.toUnicodeName, reverse: false) ?? ""
    return t.replacingOccurrences(of: "\\N{", with: "").replacingOccurrences(of: "}", with: "").lowercased()
  }
}
```

Round toggle row (bound to the editor's `icon`/`colorTag` state):
```swift
/// The "Symbol:" two-button row: an emoji toggle + a symbol toggle, each opening an anchored picker
/// popover. `icon` is the stored form ("emoji:<g>" / "sf:<name>"); writing either sets it.
struct IconToggleRow: View {
  @Binding var icon: String
  var tint: Color
  @State private var showEmoji = false
  @State private var showSymbol = false

  private var isEmoji: Bool { if case .emoji = AppearanceIcon.parse(icon) { return true }; return false }
  private var currentEmoji: String? { if case .emoji(let e) = AppearanceIcon.parse(icon) { return e }; return nil }
  private var currentSymbol: String? { if case .sfSymbol(let n) = AppearanceIcon.parse(icon) { return n }; return nil }

  var body: some View {
    HStack(spacing: 12) {
      // Emoji toggle
      Button { showEmoji = true } label: {
        ZStack {
          Circle().fill(isEmoji ? tint.opacity(0.25) : Color.secondary.opacity(0.15))
          if let e = currentEmoji { Text(e).font(.system(size: 22)) }
          else { Image(systemName: "face.smiling").font(.system(size: 20)).foregroundStyle(.secondary) }
        }.frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .popover(isPresented: $showEmoji, arrowEdge: .bottom) {
        EmojiPickerPopover { icon = "emoji:\($0)"; showEmoji = false }
      }
      // Symbol toggle
      Button { showSymbol = true } label: {
        ZStack {
          Circle().fill(!isEmoji ? tint : Color.secondary.opacity(0.15))
          Image(systemName: currentSymbol ?? "list.bullet")
            .font(.system(size: 20)).foregroundStyle(!isEmoji ? .white : .secondary)
        }.frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .popover(isPresented: $showSymbol, arrowEdge: .bottom) {
        SymbolPickerPopover(selected: currentSymbol) { icon = "sf:\($0)"; showSymbol = false }
      }
    }
  }
}
```

Emoji popover (search + category tabs + grid):
```swift
struct EmojiPickerPopover: View {
  let onPick: (String) -> Void
  @State private var query = ""
  @State private var category = EmojiCatalog.categories.first!.id

  private var shown: [String] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    if !q.isEmpty {
      return EmojiCatalog.categories.flatMap(\.emoji).filter { EmojiCatalog.name(of: $0).contains(q) }
    }
    return EmojiCatalog.categories.first { $0.id == category }?.emoji ?? []
  }

  var body: some View {
    VStack(spacing: 8) {
      TextField("Search", text: $query).textFieldStyle(.roundedBorder)
      ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 6), spacing: 6) {
          ForEach(shown, id: \.self) { e in
            Button { onPick(e) } label: { Text(e).font(.system(size: 24)) }.buttonStyle(.plain)
          }
        }
      }.frame(height: 220)
      if query.isEmpty {
        HStack(spacing: 4) {
          ForEach(EmojiCatalog.categories) { c in
            Button { category = c.id } label: {
              Image(systemName: c.symbol).font(.system(size: 13))
                .foregroundStyle(category == c.id ? Color.accentColor : .secondary)
            }.buttonStyle(.plain).frame(maxWidth: .infinity)
          }
        }
      }
    }
    .padding(10).frame(width: 300)
  }
}
```

Symbol popover (search + round-tinted grid, selected ringed):
```swift
struct SymbolPickerPopover: View {
  let selected: String?
  let onPick: (String) -> Void
  @State private var query = ""

  private var shown: [String] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    return q.isEmpty ? Self.symbols : Self.symbols.filter { $0.contains(q) }
  }

  var body: some View {
    VStack(spacing: 8) {
      TextField("Search symbols", text: $query).textFieldStyle(.roundedBorder)
      ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 6), spacing: 8) {
          ForEach(shown, id: \.self) { name in
            Button { onPick(name) } label: {
              ZStack {
                Circle().fill(Color.secondary.opacity(0.15))
                Image(systemName: name).font(.system(size: 16)).foregroundStyle(.primary)
              }
              .frame(width: 34, height: 34)
              .overlay { if selected == name { Circle().stroke(Color.accentColor, lineWidth: 2) } }
            }.buttonStyle(.plain)
          }
        }
      }.frame(height: 240)
    }
    .padding(10).frame(width: 300)
  }

  // The curated SF-symbol set (moved from NodeEditor.symbols; expanded).
  static let symbols = [ /* the T4 expanded list */ ]
}
```

`NodeEditor` right zone becomes:
```swift
        VStack(spacing: 12) {
          preview
          Text("Symbol").metaText()
          IconToggleRow(icon: $icon, tint: AppearanceStyle.color(colorTag))
        }
        .frame(width: 160)
```
Remove the old `showSymbolPopover`/`symbolQuery`/`emojiCapture`/`emojiFieldFocused`/`pickEmoji()`/
`firstEmoji(in:)`/hidden-capture-`TextField`/inline `symbolPopover`/`Self.symbols` from `NodeEditor`
(the symbol list moves into `SymbolPickerPopover`). `import AppKit` is no longer needed in
`NodeOrganizing.swift` (no `NSApp`) → remove it. Stored form and `commit()`/`load()` unchanged.

New strings: `"Search"` (de `Suchen`). `"Symbol"`, `"Search symbols"` already exist.

---

## Execution (subagent-driven, same worktree/branch)

One Sonnet implementer + task-reviewer per task; Opus whole-branch review over the **full** branch
(waves 1+2) at the end; then finish. Per-task build+smoke as before. Localization by hand (en+de),
`plutil -lint` is unreliable on `.xcstrings` — validate with
`python3 -c "import json; json.load(open('Sources/PensieveApp/Localizable.xcstrings')); print('json ok')"`.

**Human-verify carries (wave 2):**
1. Section eyebrows read as clear headers; one consistent scale; timeline rail balanced (small dot,
   no dangling stub, aligned label/time).
2. Toolbar shows exactly `[sidebar][+]` leading and `[refresh][inspector]` trailing; sidebar button
   collapses/expands the left column; the four removed actions still work from the right-click menu.
3. Inspector renders Markdown (bold, inline code, code blocks, lists); role labels clearly legible.
4. Modal: two round toggles under "Symbol:"; active mode filled accent; each opens an anchored
   search+grid popover; emoji search finds by name (e.g. "rocket" → 🚀); picking writes the badge;
   German in situ.

## Out of scope (unchanged)
Backlog item 5 (three-pane IA) and the Sharing pillar — their own specs.

---

## T9 — Single native sidebar toggle + first-party toolbar layout (post-eyeball)

**Problem.** Wave-2 T6 added a custom sidebar-toggle button + `columnVisibility` binding, but
`NavigationSplitView` already provides a native sidebar toggle (leftmost, in the sidebar) — so there
are now TWO toggles. First-party apps (Mail/Notes/Reminders) keep the toggle only leftmost in the
sidebar; put the create action + a content-column header + right-side actions per column.

**Design (mirror Mail/Notes/Reminders):**
- **Remove the custom toggle + plumbing.** In `RootView`, delete `@State private var columns` and the
  `columnVisibility: $columns` argument → plain `NavigationSplitView { } content: { } detail: { }`.
  This restores the single automatic sidebar toggle. Delete the `Image(systemName: "sidebar.left")`
  toggle Button.
- **Content-column header** (like Notes' "Alle iCloud / 227 Notizen"): on `ContentListView`'s List
  add `.navigationTitle("Pensieve")` + `.navigationSubtitle("\(model.projectCount) Projects")`.
  Remove the split-view-level `.navigationTitle("Pensieve")` (window title stays from the
  `Window("Pensieve", …)` scene). Add `AppModel.projectCount` = count of top-level project nodes:
  `allNodes.filter { $0.parentID == nil && $0.kind == NodeKind.project }.count` (expose as a computed
  `var`). *(Scope-sensitive titling — folder/count that changes with selection — is the deferred IA
  rework, backlog item 5; this is a fixed app-level header.)*
- **Actions move onto the detail column** (so they render over the detail pane, not the sidebar).
  Refactor the `detail:` closure into a `@ViewBuilder private var detailColumn` and attach `.toolbar`
  to it:
  - `ToolbarItem(placement: .navigation)` → New Node "+" (`plus`, `.help("New Node")`) — detail-leading,
    like Notes' new-note / Mail's compose.
  - `ToolbarItemGroup(placement: .primaryAction)` → Refresh (`arrow.clockwise`) then Inspector
    (`sidebar.right`) — detail-trailing.
  Remove the old split-view-level `.toolbar`. Keep all four `.sheet`/`.confirmationDialog`,
  `.inspector`, `.onChange` on the NavigationSplitView unchanged.
- **Strings:** add `"%lld Projects"` (de `"%lld Projekte"`). Remove the now-orphaned `"Toggle Sidebar"`
  key (its only consumer was the deleted custom toggle; the native toggle uses the system label).

**Human-verify:** exactly one sidebar toggle (leftmost, in the sidebar); content column shows
"Pensieve / N Projects"; "+" reads as the detail pane's leading action; refresh + inspector trailing;
sidebar toggle collapses only the left column. *(If SwiftUI hoists the `.navigation` "+" to
window-leading instead of detail-leading, that's the one spot to nudge — note it.)*
