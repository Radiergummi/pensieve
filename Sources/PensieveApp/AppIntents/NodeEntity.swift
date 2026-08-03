import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers
import PensieveKit

/// A Pensieve node as an App Intents entity — searchable in Spotlight (IndexedEntity) and openable.
/// Thin: all derivation comes from the tested `NodeFacts` kernel.
struct NodeEntity: AppEntity, IndexedEntity {
  let id: UUID
  let name: String
  let subtitle: String     // grounded facts line
  let searchBody: String   // Node.description — the searchable body

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Node")
  static let defaultQuery = NodeEntityQuery()

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
  }

  /// IndexedEntity override: only name + description are matched (spec decision #4).
  var attributeSet: CSSearchableItemAttributeSet {
    let attrs = CSSearchableItemAttributeSet(contentType: .content)
    attrs.title = name
    attrs.displayName = name
    attrs.contentDescription = searchBody.isEmpty ? subtitle : searchBody
    return attrs
  }

  init(facts: NodeFacts) {
    self.id = facts.node.id
    self.name = facts.node.name
    self.searchBody = facts.node.description
    let openLooseEndCount = facts.openLooseEnds
    let kind = String(localized: AppearanceStyle.kindLabel(facts.node.kind))
    self.subtitle = "\(kind) · \(openLooseEndCount) open loose end\(openLooseEndCount == 1 ? "" : "s") · dormant \(facts.daysDormant)d"
  }
}
