import Foundation
import SQLiteData

/// One piece of generated text that can be translated, identified the way `TranslationStore` keys it:
/// by field and by the source text itself. No ids — the store is content-keyed, so an id would be a
/// second identity for the same row and a way for a reader and a writer to disagree.
public struct TranslatableUnit: Hashable, Sendable {
  public let field: TranslationField
  public let sourceText: String
  public init(field: TranslationField, sourceText: String) {
    self.field = field
    self.sourceText = sourceText
  }
}

/// Every `(field, text)` pair `EmbeddableCorpus.gather` will look up a translation for, deduplicated.
///
/// This is the denominator of the coverage readout and the work list of the backfill — deliberately
/// one type serving both, so the number shown and the work done cannot disagree.
///
/// Eligibility is NOT restated here: the node and loose-end fetches come from
/// `EmbeddableCorpus.corpusNodes`/`corpusLooseEnds`, which `gather` itself uses. A translation of text
/// the corpus never looks up is wasted work that no surface can ever show, and a unit the corpus DOES
/// look up but this producer omits is a permanently untranslated document. `TranslatableCorpusTests`
/// pins both directions.
///
/// `TranslationField.narration` is absent by construction: narration lives in the disposable
/// `NarrationCache`, is not corpus content, and already translates automatically on open.
public enum TranslatableCorpus {
  public static func gather(_ database: any DatabaseReader) throws -> [TranslatableUnit] {
    try database.read { database in
      var seen: Set<TranslatableUnit> = []
      var units: [TranslatableUnit] = []
      // Deduplicated on the way in rather than at the end, so ORDER is the corpus's own walk order
      // (nodes then loose ends) and the progress readout advances the way the tree reads.
      func append(_ field: TranslationField, _ sourceText: String) {
        guard !sourceText.isEmpty else { return }
        let unit = TranslatableUnit(field: field, sourceText: sourceText)
        guard seen.insert(unit).inserted else { return }
        units.append(unit)
      }
      let nodes = try EmbeddableCorpus.corpusNodes(database)
      for node in nodes {
        append(.nodeName, node.name)
        append(.nodeDescription, node.description)
      }
      // The same join `gather` performs via its `stateByNodeID` lookup: a loose end under a node the
      // corpus does not cover produces no document, so it is not translatable work.
      let coveredNodeIDs = Set(nodes.map(\.id))
      for looseEnd in try EmbeddableCorpus.corpusLooseEnds(database)
      where coveredNodeIDs.contains(looseEnd.nodeID) {
        // Text ONLY, never the quote. The quote is verbatim provenance: translating it would break
        // the citation it exists to prove. `TranslationField` has no case for it; this comment
        // records why the omission is deliberate rather than forgotten.
        append(.looseEndText, looseEnd.text)
      }
      return units
    }
  }
}
