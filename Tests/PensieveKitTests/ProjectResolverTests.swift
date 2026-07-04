import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func resolverAutoCreatesAndReuses() throws {
  let db = try openCanonicalDatabase(at: tempURL("resolver"))
  let resolver = ProjectResolver(db: db)

  let a = try resolver.resolve(path: "/Users/moritz/Projects/colibri", kind: "gitRepo")
  #expect(a.project.name == "colibri")

  // Same path, different source kind → same project, new source.
  let b = try resolver.resolve(path: "/Users/moritz/Projects/colibri", kind: "claudeCode")
  #expect(b.project.id == a.project.id)
  #expect(b.source.id != a.source.id)

  let projects = try db.read { db in try Node.all.fetchAll(db) }
  #expect(projects.count == 1)
}

@Test func symlinkedPathResolvesToSameProject() throws {
  let real = tempURL("realdir", ext: nil)
  try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
  let link = tempURL("linkdir", ext: nil)
  try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
  guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil else {
    return   // symlink creation not supported in this environment; nothing to assert
  }

  let db = try openCanonicalDatabase(at: tempURL("resolver-symlink"))
  let resolver = ProjectResolver(db: db)

  let a = try resolver.resolve(path: real.path, kind: "gitRepo")
  let b = try resolver.resolve(path: link.path, kind: "gitRepo")

  #expect(a.project.id == b.project.id)
  let projects = try db.read { db in try Node.all.fetchAll(db) }
  #expect(projects.count == 1)
}

@Test func groupMergesProjects() throws {
  let db = try openCanonicalDatabase(at: tempURL("group"))
  let resolver = ProjectResolver(db: db)

  let front = try resolver.resolve(path: "/p/app-frontend", kind: "gitRepo")
  let back = try resolver.resolve(path: "/p/app-backend", kind: "gitRepo")
  try resolver.group(front.project.id, into: [back.project.id])

  let projects = try db.read { db in try Node.all.fetchAll(db) }
  #expect(projects.count == 1)
  let sources = try db.read { db in try Source.all.fetchAll(db) }
  #expect(sources.allSatisfy { $0.nodeID == front.project.id })
}

@Test func groupPreservesLooseEndsAndCheckpoints() throws {
  let db = try openCanonicalDatabase(at: tempURL("group-loose"))
  let resolver = ProjectResolver(db: db)

  let a = try resolver.resolve(path: "/p/primary", kind: "gitRepo")
  let b = try resolver.resolve(path: "/p/secondary", kind: "gitRepo")

  let event = Event(
    nodeID: b.project.id, sourceID: b.source.id, occurredAt: Date(),
    kind: "git.commit", summary: "x", detailJSON: "{}")
  try db.write { db in try Event.insert { event }.execute(db) }

  let looseEnd = LooseEnd(
    nodeID: b.project.id, sourceEventID: event.id, text: "todo", quote: "q")
  try db.write { db in try LooseEnd.insert { looseEnd }.execute(db) }

  let checkpoint = Checkpoint(nodeID: b.project.id, note: "n")
  try db.write { db in try Checkpoint.insert { checkpoint }.execute(db) }

  // A child node under B must re-parent to A on merge, not orphan.
  let child = Node(name: "b-strand", parentID: b.project.id, kind: "strand", branchKey: "feature")
  try db.write { db in try Node.insert { child }.execute(db) }

  try ProjectResolver(db: db).group(a.project.id, into: [b.project.id])

  let looseEnds = try db.read { db in try LooseEnd.all.fetchAll(db) }
  #expect(looseEnds.count == 1)
  #expect(looseEnds.first?.nodeID == a.project.id)

  let checkpoints = try db.read { db in try Checkpoint.all.fetchAll(db) }
  #expect(checkpoints.count == 1)
  #expect(checkpoints.first?.nodeID == a.project.id)

  let reparented = try db.read { db in try Node.where { $0.id.eq(child.id) }.fetchOne(db) }
  #expect(reparented?.parentID == a.project.id)
}
