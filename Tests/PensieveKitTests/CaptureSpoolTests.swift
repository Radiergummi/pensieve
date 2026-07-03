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
