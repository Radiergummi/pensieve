// Sources/PensieveApp/PassageResultsSection.swift
import PensieveKit
import SwiftUI

/// ⌥⌘F results from stored conversation passages, rendered as its own section BELOW the ranked list.
///
/// Not merged into that list, and this is a correctness point rather than a layout preference:
/// passage scores come from a different FTS5 table with a different average document length, so
/// interleaving them would order two incomparable scales against each other — the same reason
/// `SearchIndexStore.search` appends path hits instead of interleaving them.
struct PassageResultsSection: View {
  let hits: [PassageHit]
  let onOpen: (PassageHit) -> Void

  var body: some View {
    if !hits.isEmpty {
      Section {
        ForEach(hits) { hit in
          Button { onOpen(hit) } label: { PassageResultRow(hit: hit) }
            .buttonStyle(.plain)
        }
      } header: {
        Text("From your conversations")
      }
    }
  }
}

private struct PassageResultRow: View {
  let hit: PassageHit

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Image(systemName: hit.role == .prompt ? "person.crop.circle" : "sparkle")
          .foregroundStyle(.secondary)
        // Speaker is chrome and IS localized; the passage text below is captured content and is not.
        Text(hit.role == .prompt ? "You" : "Claude")
          .font(.system(size: 12, weight: .medium))
        Text(hit.nodeName)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Text(hit.occurredAt, format: .relative(presentation: .named))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        if hit.isArchived {
          Text("Archived")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }
      SnippetText(snippet: hit.snippet)
        .font(.system(size: 13))
        .lineLimit(3)
    }
    .padding(.vertical, 2)
    // The row's whole width must be hoverable/clickable — a Spacer is dead space to hit-testing,
    // which is exactly how slice A shipped unreachable hover controls.
    .rowHitArea()
  }
}
