import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers
import PensieveKit

/// One open loose end as an App Intents entity — searchable in Spotlight (IndexedEntity) and
/// openable. Thin: all content comes from the tested `LooseEndFacts` kernel. The cited `quote` is
/// folded into the searchable body so a quote phrase is findable (the whole point of 1b).
struct LooseEndEntity: AppEntity, IndexedEntity {
  let id: UUID           // the loose-end UUID
  let text: String
  let nodeName: String
  let quote: String

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Loose End")
  static let defaultQuery = LooseEndEntityQuery()

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(text)", subtitle: "\(nodeName)")
  }

  /// IndexedEntity body: title = the loose-end text; searchable content = text + the cited quote.
  var attributeSet: CSSearchableItemAttributeSet {
    let attrs = CSSearchableItemAttributeSet(contentType: .content)
    attrs.title = text
    attrs.displayName = text
    attrs.contentDescription = quote.isEmpty ? text : "\(text)\n\(quote)"
    return attrs
  }

  init(facts: LooseEndFacts) {
    self.id = facts.looseEndID
    self.text = facts.text
    self.nodeName = facts.nodeName
    self.quote = facts.quote
  }
}
