// Sources/PensieveApp/FindCommands.swift
import SwiftUI

/// Focused-value plumbing for `NodeFindState`. `@FocusedValue` on this SDK only offers
/// `init(_ keyPath:)` — there is no `init(_ objectType:)` overload for a plain `@Observable` class
/// (confirmed against the macOS 26.5 SDK's `SwiftUI.swiftinterface`) — so publishing/reading the
/// find state goes through an explicit `FocusedValueKey`, same shape as any other focused value.
struct NodeFindFocusKey: FocusedValueKey {
  typealias Value = NodeFindState
}

extension FocusedValues {
  var nodeFind: NodeFindState? {
    get { self[NodeFindFocusKey.self] }
    set { self[NodeFindFocusKey.self] = newValue }
  }
}

/// Edit ▸ Find. A separate `Commands` struct because `@FocusedValue` is a property wrapper and
/// cannot be declared inside `PensieveApp.body`'s inline `.commands { … }` block.
///
/// `CommandGroup(after: .textEditing)` is the only Edit-menu region placement SwiftUI offers — there
/// is no `.find` placement (verified against the macOS 26.5 SDK).
struct FindCommands: Commands {
  @FocusedValue(\.nodeFind) private var find

  var body: some Commands {
    CommandGroup(after: .textEditing) {
      Menu("Find") {
        Button("Find") { find?.present() }
          .keyboardShortcut("f", modifiers: .command)
          .disabled(find == nil)
        Button("Find Next") { find?.next() }
          .keyboardShortcut("g", modifiers: .command)
          .disabled(find?.hasMatches != true)
        Button("Find Previous") { find?.previous() }
          .keyboardShortcut("g", modifiers: [.command, .shift])
          .disabled(find?.hasMatches != true)
      }
    }
  }
}
