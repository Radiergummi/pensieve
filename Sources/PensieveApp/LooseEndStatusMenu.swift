// Sources/PensieveApp/LooseEndStatusMenu.swift
import SwiftUI
import PensieveKit

/// The resolve verbs for one loose end, shared by the row's context menu and its swipe actions so
/// the two can never offer different verbs. Deliberately NOT merged with the 👍/👎 thumbs: those
/// answer "was the extractor right" and feed the salience training corpus, while these answer "is
/// this handled" — conflating them would poison the corpus with work that was real but abandoned.
struct LooseEndStatusMenu: View {
  let status: LooseEndStatus
  /// Applies the chosen new status. The row supplies the previous one, so this takes only the target.
  let resolve: (LooseEndStatus) -> Void

  var body: some View {
    if status == .open {
      Button("Mark as done") { resolve(.done) }
      Button("Drop") { resolve(.dropped) }
    } else {
      Button("Reopen") { resolve(.open) }
      if status == .done {
        Button("Mark as dropped") { resolve(.dropped) }
      } else {
        Button("Mark as done") { resolve(.done) }
      }
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
