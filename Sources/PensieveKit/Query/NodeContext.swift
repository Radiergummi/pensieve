import Foundation

/// The `Node.context` string values. Centralized like `NodeKind` so a typo can't misfile a node.
/// The column stays an open `String`; `""` means unset (inherit from the nearest ancestor).
public enum NodeContext {
  public static let work = "work"
  public static let personal = "personal"
  // Unset is the empty string ("") — inherit from the nearest ancestor.

  /// The localization KEY naming a context as chrome — `nil` for a value that has no name to show.
  ///
  /// A context is NOT captured content: unlike a node name or a quote, these are values the app
  /// itself writes through a localized picker, so rendering the raw string puts a bare "work" in
  /// German chrome. Returning the key rather than the translation is what lets the app and the widget
  /// share this rule while each localizes out of its OWN catalog — an appex cannot read the app's.
  ///
  /// `nil` rather than the raw value so the caller decides the fallback, and so adding a context
  /// means editing this one switch instead of finding every surface that spells it out.
  public static func displayKey(_ context: String) -> String? {
    switch context {
    case work: return "Work"
    case personal: return "Personal"
    default: return nil
    }
  }
}

/// Pure context resolution + the Focus-filter visibility predicate. Operates on an in-memory `[Node]`
/// (the app already holds the full node set) — no DB round-trip. Tested; the app applies it thinly.
public enum NodeContextResolver {
  /// The effective context of `nodeID`: its own if set, else the nearest ancestor's; `""` if none.
  public static func resolve(_ nodeID: UUID, in nodes: [Node]) -> String {
    resolve(nodeID, byID: Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { existing, _ in existing }))
  }

  static func resolve(_ nodeID: UUID, byID: [UUID: Node]) -> String {
    var seen: Set<UUID> = []
    var cursor: UUID? = nodeID
    // `seen.insert(...).inserted` bounds a corrupt (pre-existing) parent cycle.
    while let id = cursor, seen.insert(id).inserted, let node = byID[id] {
      if !node.context.isEmpty { return node.context }
      cursor = node.parentID
    }
    return ""
  }

  /// The ids visible under `active`: resolved context equal to `active` OR unset. `active == ""`
  /// (no Focus) ⇒ every id. Generalizes to more contexts: show active + unset, hide every other.
  public static func visibleNodeIDs(for active: String, in nodes: [Node]) -> Set<UUID> {
    let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { existing, _ in existing })
    let allIDs = Set(byID.keys)
    guard !active.isEmpty else { return allIDs }
    return allIDs.filter { id in
      let ctx = resolve(id, byID: byID)
      return ctx == active || ctx.isEmpty
    }
  }
}
