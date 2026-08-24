// Sources/PensieveApp/LooseEndStatusMenu.swift
import SwiftUI
import PensieveKit

/// The resolve verbs that apply to a loose end in a given status: what each is called, what it sets,
/// and the tint the swipe affordance paints it. THE list — the row's context menu and its swipe
/// actions both build from it.
///
/// This type exists because the claim that those two were "shared" was written down and was false:
/// the swipe actions restated the open-row verbs inline and gated themselves on `status == .open`,
/// so a closed row offered Reopen from the context menu and nothing at all from a swipe. The verbs
/// are deliberately NOT merged with the 👍/👎 thumbs: those answer "was the extractor right" and feed
/// the salience training corpus, while these answer "is this handled" — conflating them would poison
/// the corpus with work that was real but abandoned.
struct LooseEndResolveVerb: Identifiable {
  /// The status this verb applies — also its identity, since a status appears at most once per list.
  let id: LooseEndStatus
  let title: LocalizedStringKey
  let tint: Color

  static func verbs(for status: LooseEndStatus) -> [LooseEndResolveVerb] {
    switch status {
    case .open:
      return [LooseEndResolveVerb(id: .done, title: "Mark as done", tint: .green),
              LooseEndResolveVerb(id: .dropped, title: "Drop", tint: .orange)]
    case .done:
      return [LooseEndResolveVerb(id: .open, title: "Reopen", tint: .blue),
              LooseEndResolveVerb(id: .dropped, title: "Mark as dropped", tint: .orange)]
    case .dropped:
      return [LooseEndResolveVerb(id: .open, title: "Reopen", tint: .blue),
              LooseEndResolveVerb(id: .done, title: "Mark as done", tint: .green)]
    }
  }
}

/// The resolve verbs for one loose end as menu items, for the row's context menu. Its swipe actions
/// render the same `LooseEndResolveVerb.verbs(for:)` list, adding each verb's tint.
struct LooseEndStatusMenu: View {
  let status: LooseEndStatus
  /// Applies the chosen new status. The row supplies the previous one, so this takes only the target.
  let resolve: (LooseEndStatus) -> Void

  var body: some View {
    ForEach(LooseEndResolveVerb.verbs(for: status)) { verb in
      Button(verb.title) { resolve(verb.id) }
    }
  }
}

/// Marks a closed loose end with the verb that closed it. Renders nothing for an open one, so the
/// same row builder serves both feeds.
struct LooseEndStatusBadge: View {
  let status: LooseEndStatus
  var body: some View {
    switch status {
    case .open: EmptyView()
    // Own catalog keys, NOT the bare "Done" — that key exists and belongs to FindBar's dismiss
    // button, where its German is "Fertig".
    case .done: badge(Text("Loose end done"), .green)
    case .dropped: badge(Text("Loose end dropped"), .secondary)
    }
  }

  private func badge(_ label: Text, _ tint: Color) -> some View {
    label
      .font(.caption2)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(.quaternary, in: Capsule())
      .foregroundStyle(tint)
  }
}

/// The selected row of a loose-end feed, published as a focused SCENE value so the Edit-menu verbs act
/// on the focused window's selection. Published ONLY while the middle column shows a feed — the verbs
/// must be disabled everywhere else rather than acting on a stale selection. Re-derived from the live
/// items array on every body pass, so a selection whose row has left the feed resolves to nil.
struct LooseEndSelection {
  let looseEndID: UUID
  let status: LooseEndStatus
  let resolve: (LooseEndStatus) -> Void

  var canClose: Bool { status == .open }
  var canReopen: Bool { status.isClosed }
}

/// Focused-value plumbing for `LooseEndSelection`, the same explicit-`FocusedValueKey` shape
/// `NodeFindFocusKey` uses and for the same SDK reason documented there.
struct LooseEndSelectionFocusKey: FocusedValueKey {
  typealias Value = LooseEndSelection
}

extension FocusedValues {
  var looseEndSelection: LooseEndSelection? {
    get { self[LooseEndSelectionFocusKey.self] }
    set { self[LooseEndSelectionFocusKey.self] = newValue }
  }
}

/// Resolve verbs for the selected row of a loose-end feed. `⌘⏎` / `⌥⌘⏎` / `⇧⌘⏎` deliberately avoid
/// bare letters (List type-ahead) and the shipped ⌘F / ⌥⌘F / ⌘G find bindings.
///
/// Deliberately NOT built from `LooseEndResolveVerb.verbs(for:)`, unlike the row's context menu and
/// swipe actions: a menu-bar menu must be a STABLE list whose items grey out, not one whose items
/// appear and disappear with the selection — so all three verbs are always present and `.disabled`
/// carries the status rule. Its titles are Title Case for the same reason (macOS menu convention),
/// which is why they are separate catalog keys from the row's sentence-case ones.
///
/// Without these the queue is pointer-only, and the undo `resolveLooseEnd` registers is justified by
/// "a mis-key must be one ⌘Z away" with no key to mis-hit. At 968 items this is the difference
/// between a queue and a chore.
struct LooseEndResolveCommands: Commands {
  @FocusedValue(\.looseEndSelection) private var selection: LooseEndSelection?

  var body: some Commands {
    CommandGroup(after: .pasteboard) {
      Divider()
      Button("Mark as Done") { selection?.resolve(.done) }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(selection?.canClose != true)
      Button("Drop") { selection?.resolve(.dropped) }
        .keyboardShortcut(.return, modifiers: [.option, .command])
        .disabled(selection?.canClose != true)
      Button("Reopen") { selection?.resolve(.open) }
        .keyboardShortcut(.return, modifiers: [.shift, .command])
        .disabled(selection?.canReopen != true)
    }
  }
}
