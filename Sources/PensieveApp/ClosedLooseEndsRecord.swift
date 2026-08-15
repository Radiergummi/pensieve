// Sources/PensieveApp/ClosedLooseEndsRecord.swift
import SwiftUI
import PensieveKit

/// The detail pane's collapsed record of loose ends already done or dropped. Its own file because
/// `DetailView.swift` sits at SwiftLint's 400-line cap; the placement rules below are the reason it
/// must stay the LAST thing that pane renders.
///
/// Rendered by the caller only when non-empty: an always-present "Done · 0" would announce a slot that
/// is usually empty, the same failure the recap's removed caps header had.
///
/// Deliberately NOT indexed by in-node ⌘F (spec §7.1). The find document pre-allocates a slot per
/// loose end in on-screen order, and these rows render after the narration and every activity row —
/// so appending their slots later stays compatible, whereas placing this section inside Loose Ends
/// would recreate the slice-A × in-node-find ordering defect. Known day-one consequence, accepted:
/// ⌘F over an expanded record reports no matches for text plainly on screen.
struct ClosedLooseEndsRecord: View {
  var model: AppModel
  let items: [LooseEndView]
  /// Bound, not merely default-collapsed: ⌥⌘F's widened scope can land on a closed end, and a
  /// collapsed disclosure whose rows carried no `.id` left the pane with no highlight, no expansion
  /// and no scroll — the hit was findable but not showable.
  @Binding var isExpanded: Bool
  let undoManager: UndoManager?

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      // LAZY for the same reason the open section above it is: a plain `ForEach` here builds every
      // row the moment the disclosure opens. Latent today only because no node has closed ends yet —
      // `resolveAllOpen` moves a whole node's worth in one action, and the largest is 288. Unlike the
      // open section this one is not measured, because there is currently nothing to measure; it is
      // the same container defect in the same pane.
      LazyVStack(alignment: .leading, spacing: 8) {
        ForEach(items, id: \.looseEnd.id) { view in
          HStack(alignment: .top, spacing: 8) {
            LooseEndStatusBadge(status: view.looseEnd.status)
            LooseEndRow(view: view, loadProvenance: model.provenance,
                        onLabel: model.setLooseEndLabel,
                        displaySummary: model.displayed(field: .looseEndText,
                                                        sourceText: view.looseEnd.text),
                        onTranslate: { text in await model.translate(field: .looseEndText, sourceText: text) },
                        onResolve: { id, status, previous, previousStamp in
                          model.resolveLooseEnd(id, status, previous: previous,
                                                previousResolvedAt: previousStamp,
                                                undoManager: undoManager)
                        },
                        expandedLooseEndID: model.expandedLooseEndID,
                        compact: false)
          }
          .id(view.looseEnd.id)
        }
      }
    } label: {
      Text("Done · \(items.count)").font(.callout).foregroundStyle(.secondary)
    }
  }
}
