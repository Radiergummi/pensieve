// Sources/PensieveKit/Query/NodeFindDocument.swift
import Foundation

/// Where a findable piece of text lives in the detail pane. The single vocabulary Kit and the app
/// share for "where is this match": it is simultaneously the scroll target (`.id(anchor)`) and the
/// expansion instruction (a `.transcriptSegment` names the row to open).
public enum FindAnchor: Hashable, Sendable {
  case nodeName
  case description
  case narration
  case looseEndText(UUID)
  case looseEndQuote(UUID)
  case transcriptSegment(looseEndID: UUID, messageIndex: Int, segment: Int)
  case event(UUID)

  /// The loose end whose row the app must EXPAND to reach this anchor.
  ///
  /// Deliberately NOT "the loose end this anchor belongs to": a `.looseEndText` match sits in the
  /// row's always-visible header, so expanding for it would throw the whole provenance box open on
  /// every ⌘G through a node's loose-end text. Only the quote fallback and the transcript segments
  /// live behind the disclosure.
  public var looseEndIDRequiringExpansion: UUID? {
    switch self {
    case .looseEndQuote(let id): return id
    case .transcriptSegment(let id, _, _): return id
    case .looseEndText, .nodeName, .description, .narration, .event: return nil
    }
  }
}

/// One findable text unit: some text, and where it is rendered.
public struct FindUnit: Hashable, Sendable {
  public let anchor: FindAnchor
  public let text: String
  public init(anchor: FindAnchor, text: String) { self.anchor = anchor; self.text = text }
}

/// One occurrence. `offset`/`length` are CHARACTER positions within the unit's text (not
/// `String.Index`) so a match survives being stored, compared and carried across a document rebuild.
public struct FindMatch: Hashable, Sendable {
  public let anchor: FindAnchor
  public let offset: Int
  public let length: Int
  public let ordinal: Int   // 1-based, document order

  public var identity: FindMatchIdentity { FindMatchIdentity(anchor: anchor, offset: offset) }
}

/// A match's stable identity — what the find bar tracks INSTEAD of an ordinal, so a background
/// provenance fill that inserts earlier matches cannot renumber the user's position out from under
/// them.
public struct FindMatchIdentity: Hashable, Sendable {
  public let anchor: FindAnchor
  public let offset: Int
  public init(anchor: FindAnchor, offset: Int) { self.anchor = anchor; self.offset = offset }
}

/// The ordered, findable projection of one node's detail pane.
///
/// Order is fixed at construction to match on-screen order: What It Is (name, description) → Loose
/// Ends (each row's text, then its provenance slot) → the recap → Recent Activity. Provenance
/// arrives later and asynchronously, so each loose end owns a PRE-ALLOCATED slot the sweep fills in
/// place — appending would order matches by file-completion order and ⌘G would walk the pane in a
/// jumbled sequence.
public struct NodeFindDocument: Equatable, Sendable {
  /// A slot is either a fixed unit or a loose end's provenance, which resolves to transcript units
  /// OR the stored quote — never both (the quote is only rendered in the unavailable fallback, and
  /// it is a substring of the cited message).
  enum Slot: Equatable, Sendable {
    case unit(FindUnit)
    case provenance(looseEndID: UUID, resolved: [FindUnit]?)
  }

  private var slots: [Slot]

  /// Every findable unit, in document order. Unresolved provenance slots contribute nothing yet.
  public var units: [FindUnit] {
    slots.flatMap { slot -> [FindUnit] in
      switch slot {
      case .unit(let unit): return [unit]
      case .provenance(_, let resolved): return resolved ?? []
      }
    }
  }

  /// Loose ends whose provenance the sweep has not resolved yet, in document order.
  public var unresolvedLooseEndIDs: [UUID] {
    slots.compactMap { slot in
      if case .provenance(let looseEndID, let resolved) = slot, resolved == nil { return looseEndID }
      return nil
    }
  }

  public static func make(node: Node, narration: String?, looseEnds: [LooseEndView],
                          events: [Event], showsLooseEnds: Bool) -> NodeFindDocument {
    var slots: [Slot] = []
    slots.append(.unit(FindUnit(anchor: .nodeName, text: node.name)))
    if !node.description.isEmpty {
      slots.append(.unit(FindUnit(anchor: .description, text: node.description)))
    }
    // The one-home rule: when the middle column owns this node's loose ends the detail renders no
    // Loose Ends section, so indexing them would produce unreachable matches.
    if showsLooseEnds {
      for view in looseEnds {
        slots.append(.unit(FindUnit(anchor: .looseEndText(view.looseEnd.id), text: view.looseEnd.text)))
        slots.append(.provenance(looseEndID: view.looseEnd.id, resolved: nil))
      }
    }
    // AFTER the loose ends, because that is where the recap renders: cited content leads, best-effort
    // prose closes. nil when the section is not rendered — disabled toggle, or no genuine narration.
    if let narration, !narration.isEmpty {
      slots.append(.unit(FindUnit(anchor: .narration, text: narration)))
    }
    for event in events {
      slots.append(.unit(FindUnit(anchor: .event(event.id), text: event.summary)))
    }
    return NodeFindDocument(slots: slots)
  }

  /// Resolves a loose end's slot to its transcript units, in place.
  public mutating func fill(looseEndID: UUID, units: [FindUnit]) {
    resolve(looseEndID: looseEndID, with: units)
  }

  /// Resolves a loose end's slot to the stored quote — the honest fallback when the transcript is
  /// gone (85% of loose ends on the measured store).
  public mutating func fillWithQuoteFallback(looseEndID: UUID, quote: String) {
    let units = quote.isEmpty ? [] : [FindUnit(anchor: .looseEndQuote(looseEndID), text: quote)]
    resolve(looseEndID: looseEndID, with: units)
  }

  private mutating func resolve(looseEndID: UUID, with units: [FindUnit]) {
    for index in slots.indices {
      if case .provenance(let slotID, _) = slots[index], slotID == looseEndID {
        slots[index] = .provenance(looseEndID: looseEndID, resolved: units)
        return
      }
    }
  }

  public func text(for anchor: FindAnchor) -> String? {
    units.first { $0.anchor == anchor }?.text
  }

  /// Every occurrence of `query`, in document order, ordinal-numbered from 1.
  public func matches(query: String) -> [FindMatch] {
    var found: [FindMatch] = []
    for unit in units {
      for range in FindMatcher.ranges(in: unit.text, query: query) {
        let offset = unit.text.distance(from: unit.text.startIndex, to: range.lowerBound)
        let length = unit.text.distance(from: range.lowerBound, to: range.upperBound)
        found.append(FindMatch(anchor: unit.anchor, offset: offset, length: length,
                               ordinal: found.count + 1))
      }
    }
    return found
  }
}

extension NodeFindDocument {
  /// Builds a document from bare units, bypassing section ordering. **Test support only** — product
  /// code must go through `make(node:…)` so document order stays tied to on-screen order.
  public static func testing(units: [FindUnit]) -> NodeFindDocument {
    NodeFindDocument(slots: units.map { .unit($0) })
  }
}

extension NodeFindDocument {
  /// Turns a loaded provenance window into findable units. The ONE place transcript anchors are
  /// minted, so the app cannot invent an ordinal the view doesn't render.
  ///
  /// `segment` is the index in the message's FULL segment array — the same array
  /// `TranscriptMessageView` enumerates by offset. Segments with no displayed text are skipped but
  /// do NOT shift their neighbours' ordinals.
  public static func units(from loaded: LoadedProvenance, looseEndID: UUID) -> [FindUnit] {
    guard loaded.context.transcriptAvailable else { return [] }
    var units: [FindUnit] = []
    for (position, message) in loaded.context.messages.enumerated() {
      guard position < loaded.segments.count else { continue }
      for (ordinal, segment) in loaded.segments[position].enumerated() {
        guard let text = segment.findableText else { continue }
        units.append(FindUnit(anchor: .transcriptSegment(looseEndID: looseEndID,
                                                          messageIndex: message.index,
                                                          segment: ordinal),
                              text: text))
      }
    }
    return units
  }
}
