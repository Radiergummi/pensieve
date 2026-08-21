import Testing
import Foundation
import SQLiteData
@testable import PensieveKit

/// Builds a node with one event and `openLooseEnds` open loose ends, mirroring `NextQueriesTests`.
private func seedProject(_ database: any DatabaseWriter, path: String, context: String?,
                         openLooseEnds: Int) throws -> Node {
  let resolver = ProjectResolver(database: database)
  let (node, source) = try resolver.resolve(path: path, kind: SourceKind.claudeCode)
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}",
                    fingerprint: "fingerprint-\(path)")
  try database.write { database in
    try Event.insert { event }.execute(database)
    for index in 0..<openLooseEnds {
      try LooseEnd.insert {
        LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t\(index)", quote: "q\(index)")
      }.execute(database)
    }
    if let context {
      try Node.where { $0.id.eq(node.id) }.update { $0.context = #bind(context) }.execute(database)
    }
  }
  return node
}

@Test func publishWritesADecodableDigestOrderedByRank() throws {
  let database = try openCanonicalDatabase(at: tempURL("widget-publish"))
  _ = try seedProject(database, path: "/p/quiet", context: nil, openLooseEnds: 0)
  let busy = try seedProject(database, path: "/p/busy", context: nil, openLooseEnds: 5)
  let destination = tempURL("digest", ext: "json")

  try WidgetDigestPublisher.publish(database: database, now: Date(),
                                    activeContext: "", to: destination)

  let digest = try #require(WidgetDigest.read(from: destination))
  #expect(digest.schemaVersion == WidgetDigest.currentSchemaVersion)
  #expect(digest.items.first?.nodeID == busy.id)   // ranking is NextQueries', not ours
  #expect(digest.items.first?.openLooseEnds == 5)
}

/// The widget must agree with the window, the menu bar and Spotlight. It cannot read the app's
/// defaults domain (different bundle id, and it is sandboxed), so filtering happens at publish time.
@Test func publishFiltersByActiveFocusContext() throws {
  let database = try openCanonicalDatabase(at: tempURL("widget-focus"))
  let work = try seedProject(database, path: "/p/work", context: NodeContext.work, openLooseEnds: 2)
  let personal = try seedProject(database, path: "/p/home", context: NodeContext.personal, openLooseEnds: 2)
  let destination = tempURL("digest-focus", ext: "json")

  try WidgetDigestPublisher.publish(database: database, now: Date(),
                                    activeContext: NodeContext.work, to: destination)

  let digest = try #require(WidgetDigest.read(from: destination))
  #expect(digest.context == NodeContext.work)
  #expect(digest.items.contains { $0.nodeID == work.id })
  #expect(!digest.items.contains { $0.nodeID == personal.id })
}

@Test func publishCapsTheItemCount() throws {
  let database = try openCanonicalDatabase(at: tempURL("widget-cap"))
  for index in 0..<(WidgetDigest.maximumItems + 3) {
    _ = try seedProject(database, path: "/p/n\(index)", context: nil, openLooseEnds: index + 1)
  }
  let destination = tempURL("digest-cap", ext: "json")

  try WidgetDigestPublisher.publish(database: database, now: Date(),
                                    activeContext: "", to: destination)

  let digest = try #require(WidgetDigest.read(from: destination))
  #expect(digest.items.count == WidgetDigest.maximumItems)
}
