// Sources/PensieveKit/Query/FindSession.swift
import Foundation

/// The find bar's navigation state, as a pure value: which query, which matches, and which one the
/// user is standing on.
///
/// It tracks the current match by **identity** (anchor + character offset), not by ordinal, because
/// the document mutates underneath it: the transcript sweep fills provenance slots in document
/// order, so matches appear AHEAD of the user's position. Holding an ordinal would silently move
/// them to a different match; holding an identity renumbers around them.
public struct FindSession: Sendable {
  public private(set) var query: String = ""
  public private(set) var matches: [FindMatch] = []
  private var document: NodeFindDocument
  private var currentIdentity: FindMatchIdentity?

  public init(document: NodeFindDocument) { self.document = document }

  public var matchCount: Int { matches.count }
  public var hasMatches: Bool { !matches.isEmpty }

  public var current: FindMatch? {
    guard let currentIdentity else { return nil }
    return matches.first { $0.identity == currentIdentity }
  }

  public var currentOrdinal: Int? { current?.ordinal }

  public mutating func setQuery(_ query: String) {
    self.query = query
    matches = document.matches(query: query)
    currentIdentity = matches.first?.identity   // a new query always starts at the first match
  }

  /// Re-runs the query against a mutated document (a provenance fill, a narration refresh),
  /// preserving the user's position where possible.
  public mutating func update(document: NodeFindDocument) {
    let previousOrdinal = current?.ordinal
    self.document = document
    matches = document.matches(query: query)
    guard !matches.isEmpty else { currentIdentity = nil; return }
    if let currentIdentity, matches.contains(where: { $0.identity == currentIdentity }) {
      return   // same match, possibly renumbered — nothing to do
    }
    // The held match is gone (a re-parsed transcript failed the guard, or ⌘R replaced the
    // narration). Re-anchor to the same POSITION in the list, clamped — deterministic, and the
    // closest thing to "the nearest following match" without re-deriving vanished document offsets.
    let target = min(previousOrdinal ?? 1, matches.count)
    currentIdentity = matches[target - 1].identity
  }

  public mutating func next() { step(by: 1) }
  public mutating func previous() { step(by: -1) }

  private mutating func step(by delta: Int) {
    guard !matches.isEmpty else { currentIdentity = nil; return }
    guard let ordinal = current?.ordinal else {
      currentIdentity = matches.first?.identity
      return
    }
    let zeroBased = (ordinal - 1 + delta + matches.count) % matches.count
    currentIdentity = matches[zeroBased].identity
  }

  public mutating func clear() {
    query = ""
    matches = []
    currentIdentity = nil
  }
}
