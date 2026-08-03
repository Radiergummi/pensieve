import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func resolverAutoCreatesAndReuses() throws {
  let database = try openCanonicalDatabase(at: tempURL("resolver"))
  let resolver = ProjectResolver(database: database)

  let gitRepoResolution = try resolver.resolve(path: "/Users/moritz/Projects/colibri", kind: "gitRepo")
  #expect(gitRepoResolution.project.name == "colibri")

  // Same path, different source kind → same project, new source.
  let claudeCodeResolution = try resolver.resolve(path: "/Users/moritz/Projects/colibri", kind: "claudeCode")
  #expect(claudeCodeResolution.project.id == gitRepoResolution.project.id)
  #expect(claudeCodeResolution.source.id != gitRepoResolution.source.id)

  let projects = try database.read { database in try Node.all.fetchAll(database) }
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

  let database = try openCanonicalDatabase(at: tempURL("resolver-symlink"))
  let resolver = ProjectResolver(database: database)

  let realResolution = try resolver.resolve(path: real.path, kind: "gitRepo")
  let symlinkResolution = try resolver.resolve(path: link.path, kind: "gitRepo")

  #expect(realResolution.project.id == symlinkResolution.project.id)
  let projects = try database.read { database in try Node.all.fetchAll(database) }
  #expect(projects.count == 1)
}

@Test func groupMergesProjects() throws {
  let database = try openCanonicalDatabase(at: tempURL("group"))
  let resolver = ProjectResolver(database: database)

  let front = try resolver.resolve(path: "/p/app-frontend", kind: "gitRepo")
  let back = try resolver.resolve(path: "/p/app-backend", kind: "gitRepo")
  try resolver.group(front.project.id, into: [back.project.id])

  let projects = try database.read { database in try Node.all.fetchAll(database) }
  #expect(projects.count == 1)
  let sources = try database.read { database in try Source.all.fetchAll(database) }
  #expect(sources.allSatisfy { $0.nodeID == front.project.id })
}

@Test func groupPreservesLooseEndsAndCheckpoints() throws {
  let database = try openCanonicalDatabase(at: tempURL("group-loose"))
  let resolver = ProjectResolver(database: database)

  let primaryResolution = try resolver.resolve(path: "/p/primary", kind: "gitRepo")
  let secondaryResolution = try resolver.resolve(path: "/p/secondary", kind: "gitRepo")

  let event = Event(
    nodeID: secondaryResolution.project.id, sourceID: secondaryResolution.source.id, occurredAt: Date(),
    kind: "git.commit", summary: "x", detailJSON: "{}")
  try database.write { database in try Event.insert { event }.execute(database) }

  let looseEnd = LooseEnd(
    nodeID: secondaryResolution.project.id, sourceEventID: event.id, text: "todo", quote: "q")
  try database.write { database in try LooseEnd.insert { looseEnd }.execute(database) }

  let checkpoint = Checkpoint(nodeID: secondaryResolution.project.id, note: "n")
  try database.write { database in try Checkpoint.insert { checkpoint }.execute(database) }

  // A child node under B must re-parent to A on merge, not orphan.
  let child = Node(name: "b-strand", parentID: secondaryResolution.project.id, kind: .strand, branchKey: "feature")
  try database.write { database in try Node.insert { child }.execute(database) }

  try ProjectResolver(database: database).group(primaryResolution.project.id, into: [secondaryResolution.project.id])

  let looseEnds = try database.read { database in try LooseEnd.all.fetchAll(database) }
  #expect(looseEnds.count == 1)
  #expect(looseEnds.first?.nodeID == primaryResolution.project.id)

  let checkpoints = try database.read { database in try Checkpoint.all.fetchAll(database) }
  #expect(checkpoints.count == 1)
  #expect(checkpoints.first?.nodeID == primaryResolution.project.id)

  let reparented = try database.read { database in try Node.where { $0.id.eq(child.id) }.fetchOne(database) }
  #expect(reparented?.parentID == primaryResolution.project.id)
}

@Test func groupMergingParentIntoChildRerootsAtGrandparent() throws {
  let database = try openCanonicalDatabase(at: tempURL("group-selfcycle"))
  let grand = try #require(try NodeCommands.add(database, name: "Grand", kind: .domain, parent: nil, description: ""))
  let parent = try #require(try NodeCommands.add(database, name: "Parent", kind: .project, parent: "Grand", description: ""))
  let child = try #require(try NodeCommands.add(database, name: "Child", kind: .strand, parent: "Parent", description: ""))

  try ProjectResolver(database: database).group(child.id, into: [parent.id])   // merge parent INTO its own child

  let reloaded = try database.read { database in try Node.where { $0.id.eq(child.id) }.fetchOne(database) }
  #expect(reloaded != nil)
  #expect(reloaded?.parentID == grand.id)     // promoted to grandparent…
  #expect(reloaded?.parentID != child.id)     // …never itself
  #expect(try database.read { database in try Node.where { $0.id.eq(parent.id) }.fetchOne(database) } == nil)  // parent gone
}

@Test func groupMergingRootParentIntoChildMakesChildRoot() throws {
  let database = try openCanonicalDatabase(at: tempURL("group-selfcycle-root"))
  let parent = try #require(try NodeCommands.add(database, name: "Parent", kind: .project, parent: nil, description: ""))
  let child = try #require(try NodeCommands.add(database, name: "Child", kind: .strand, parent: "Parent", description: ""))

  try ProjectResolver(database: database).group(child.id, into: [parent.id])

  let reloaded = try database.read { database in try Node.where { $0.id.eq(child.id) }.fetchOne(database) }
  #expect(reloaded?.parentID == nil)   // parent was a root → child becomes a root
}

@Test func groupMergingAncestorChainInOneCallHasNoCycle() throws {
  let database = try openCanonicalDatabase(at: tempURL("group-multiancestor"))
  let grand = try #require(try NodeCommands.add(database, name: "Grand", kind: .domain, parent: nil, description: ""))
  let parent = try #require(try NodeCommands.add(database, name: "Parent", kind: .project, parent: "Grand", description: ""))
  let child = try #require(try NodeCommands.add(database, name: "Child", kind: .strand, parent: "Parent", description: ""))

  try ProjectResolver(database: database).group(child.id, into: [grand.id, parent.id])   // whole chain in one call

  let reloaded = try database.read { database in try Node.where { $0.id.eq(child.id) }.fetchOne(database) }
  #expect(reloaded != nil)
  #expect(reloaded?.parentID == nil)        // survivor rises to root, no self/loop
  #expect(reloaded?.parentID != child.id)
  #expect(try database.read { database in try Node.all.fetchAll(database) }.count == 1)   // grand + parent gone
}

@Test func groupMergingNonAdjacentAncestorHasNoCycle() throws {
  let database = try openCanonicalDatabase(at: tempURL("group-nonadjacent"))
  let root = try #require(try NodeCommands.add(database, name: "Root", kind: .domain, parent: nil, description: ""))
  let middle = try #require(try NodeCommands.add(database, name: "Middle", kind: .project, parent: "Root", description: ""))
  let leaf = try #require(try NodeCommands.add(database, name: "Leaf", kind: .strand, parent: "Middle", description: ""))

  try ProjectResolver(database: database).group(leaf.id, into: [root.id])   // merge non-adjacent grandparent into leaf

  let reloadedLeaf = try database.read { database in try Node.where { $0.id.eq(leaf.id) }.fetchOne(database) }
  let reloadedMiddle = try database.read { database in try Node.where { $0.id.eq(middle.id) }.fetchOne(database) }
  #expect(reloadedLeaf?.parentID == nil)          // leaf takes root's position
  #expect(reloadedMiddle?.parentID == leaf.id)    // middle hangs under the survivor
  #expect(reloadedLeaf?.parentID != leaf.id)
}
