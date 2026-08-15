import Foundation
import Testing
import SQLiteData
@testable import PensieveKit

@Test func fixtureSeedsTheShapeTheUITestsAssert() throws {
  let url = tempURL("uifixture")
  let now = Date(timeIntervalSince1970: 1_770_000_000)
  try UITestFixture.seed(canonicalAt: url, now: now)

  let database = try openCanonicalDatabase(at: url)

  let nodes = try database.read { database in try Node.all.fetchAll(database) }
  #expect(nodes.count == 6)

  // The tree the sidebar renders: Colibri nests under the Work domain, and the strand under Colibri.
  let colibri = try #require(nodes.first { $0.id == UITestFixture.Identifiers.colibri })
  #expect(colibri.parentID == UITestFixture.Identifiers.workDomain)
  let strand = try #require(nodes.first { $0.id == UITestFixture.Identifiers.colibriStrand })
  #expect(strand.parentID == UITestFixture.Identifiers.colibri)
  #expect(strand.kind == NodeKind.strand)

  // Exactly one archived node — the Archived sidebar section asserts on this count.
  #expect(nodes.filter { $0.state == NodeState.archived }.count == 1)

  // Focus filtering needs one node of each explicit context, and unset nodes to prove they always show.
  #expect(nodes.filter { $0.context == "work" }.count == 1)
  #expect(nodes.filter { $0.context == "personal" }.count == 1)

  // Open vs closed loose ends drive the sidebar counts and the collapsed "Done · N" record.
  let looseEnds = try database.read { database in try LooseEnd.all.fetchAll(database) }
  let open = looseEnds.filter { $0.status == LooseEndStatus.open && $0.label != "noise" }
  #expect(open.count == 3)
  #expect(looseEnds.filter { $0.status == LooseEndStatus.done }.count == 1)

  // The quote is what the provenance row renders verbatim; the UI test greps for it.
  #expect(open.contains { $0.quote == UITestFixture.colibriOpenLooseEndQuote })

  // Dates are offsets from the injected now, so relative labels are stable across runs.
  let events = try database.read { database in try Event.all.fetchAll(database) }
  #expect(events.allSatisfy { $0.occurredAt <= now })
  #expect(events.contains { now.timeIntervalSince($0.occurredAt) < 3 * 3600 })      // "recently active"
  #expect(events.contains { now.timeIntervalSince($0.occurredAt) > 30 * 86_400 })   // dormant
}
