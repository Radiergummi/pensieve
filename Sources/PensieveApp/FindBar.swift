// Sources/PensieveApp/FindBar.swift
import SwiftUI
import PensieveKit

/// The detail column's find bar. Standard macOS Find grammar: a field, a match count, previous/next,
/// and Done. Esc dismisses (wired by the caller's `.onExitCommand`).
struct FindBar: View {
  var find: NodeFindState
  @FocusState private var isFieldFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
      TextField("Find in this project", text: Binding(get: { find.query },
                                                      set: { find.setQuery($0) }))
        .textFieldStyle(.plain)
        .focused($isFieldFocused)
        .onSubmit { find.next() }

      Text(countLabel).metaText().monospacedDigit()

      Button { find.previous() } label: { Image(systemName: "chevron.up") }
        .buttonStyle(.borderless).disabled(!find.hasMatches)
        .help("Find Previous")
      Button { find.next() } label: { Image(systemName: "chevron.down") }
        .buttonStyle(.borderless).disabled(!find.hasMatches)
        .help("Find Next")
      Button("Done") { find.dismiss() }
        .buttonStyle(.borderless)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    .onAppear { isFieldFocused = true }
  }

  private var countLabel: String {
    if find.isSweeping {
      return String(localized: "\(find.matchCount) matches · searching transcripts \(find.sweepDone)/\(find.sweepTotal)")
    }
    guard find.hasMatches else {
      return find.query.isEmpty ? "" : String(localized: "No matches")
    }
    return String(localized: "\(find.currentOrdinal ?? 1) of \(find.matchCount)")
  }
}
