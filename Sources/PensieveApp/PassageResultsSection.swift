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

  /// A stored passage already knows which side of the turn it came from, so this is a direct
  /// mapping rather than `SpeakerClass.of`'s inference over a raw transcript role — but it resolves
  /// to the same two cases, and therefore to the same localized labels.
  private var speaker: SpeakerClass { hit.role == .prompt ? .you : .claude }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Image(systemName: hit.role == .prompt ? "person.crop.circle" : "sparkle")
          .foregroundStyle(.secondary)
        // Speaker is chrome and IS localized; the passage text below is captured content and is not.
        // The label comes from `SpeakerClass`, the app's one speaker vocabulary, so this row cannot
        // say "You" where the transcript views it links into say something else.
        Text(speaker.label)
          .font(.system(size: 12, weight: .medium))
        Text(hit.nodeName).metaText()
        Spacer(minLength: 0)
        Text(hit.occurredAt, format: NodeMeta.relativeStyle).metaText()
        if hit.isArchived { ArchivedBadge() }
      }
      SnippetText(snippet: hit.snippet)
        .font(.system(size: 13))
    }
    .padding(.vertical, 2)
    // The row's whole width must be hoverable/clickable — a Spacer is dead space to hit-testing,
    // which is exactly how slice A shipped unreachable hover controls.
    .rowHitArea()
  }
}
