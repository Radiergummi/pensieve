import Foundation
import Testing
@testable import PensieveKit

@Test func spoolAppendsAndDrains() throws {
  let spool = try CaptureSpool(at: tempURL("capture"))

  try spool.append(kind: "git.commit", payload: #"{"hash":"abc"}"#)
  try spool.append(kind: "cc.session", payload: #"{"path":"/x.jsonl"}"#)

  var pending = try spool.pending()
  #expect(pending.count == 2)

  try spool.markIngested([pending[0].id])
  pending = try spool.pending()
  #expect(pending.count == 1)
  #expect(pending.first?.kind == "cc.session")
}

@Test func lastCaptureAtReflectsNewestRowEvenAfterIngest() throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  #expect(try spool.lastCaptureAt() == nil)                     // empty spool

  let t1 = Date(timeIntervalSince1970: 1_000_000)
  let t2 = Date(timeIntervalSince1970: 2_000_000)
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}", at: t1)
  try spool.append(kind: CaptureKind.ccSession, payload: "{}", at: t2)
  #expect(abs(try spool.lastCaptureAt()!.timeIntervalSince(t2)) < 1)   // newest wins

  let ids = try spool.pending().map(\.id)
  try spool.markIngested(ids)
  #expect(try spool.pendingCount() == 0)
  #expect(abs(try spool.lastCaptureAt()!.timeIntervalSince(t2)) < 1)   // survives ingest
}

@Test func pendingCountCountsOnlyUningested() throws {
  let spool = try CaptureSpool(at: tempURL("spool"))
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}")
  try spool.append(kind: CaptureKind.gitCommit, payload: "{}")
  #expect(try spool.pendingCount() == 2)
  try spool.markIngested([try spool.pending().first!.id])
  #expect(try spool.pendingCount() == 1)
}
