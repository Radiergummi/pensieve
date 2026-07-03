import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func resolverAutoCreatesAndReuses() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("resolver-\(UUID().uuidString).sqlite")
  let db = try openCanonicalDatabase(at: url)
  let resolver = ProjectResolver(db: db)

  let a = try resolver.resolve(path: "/Users/moritz/Projects/colibri", kind: "gitRepo")
  #expect(a.project.name == "colibri")

  // Same path, different source kind → same project, new source.
  let b = try resolver.resolve(path: "/Users/moritz/Projects/colibri", kind: "claudeCode")
  #expect(b.project.id == a.project.id)
  #expect(b.source.id != a.source.id)

  let projects = try db.read { db in try Project.all.fetchAll(db) }
  #expect(projects.count == 1)
}

@Test func groupMergesProjects() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("group-\(UUID().uuidString).sqlite")
  let db = try openCanonicalDatabase(at: url)
  let resolver = ProjectResolver(db: db)

  let front = try resolver.resolve(path: "/p/app-frontend", kind: "gitRepo")
  let back = try resolver.resolve(path: "/p/app-backend", kind: "gitRepo")
  try resolver.group(front.project.id, into: [back.project.id])

  let projects = try db.read { db in try Project.all.fetchAll(db) }
  #expect(projects.count == 1)
  let sources = try db.read { db in try Source.all.fetchAll(db) }
  #expect(sources.allSatisfy { $0.projectID == front.project.id })
}
