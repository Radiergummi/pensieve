import Testing
import Foundation
@testable import PensieveKit

@Test func appendCreatesFileAndAppends() throws {
  let url = tempURL("synclog-create", ext: "log")
  defer { try? FileManager.default.removeItem(at: url) }

  SyncLog.append("first line\n", to: url)
  SyncLog.append("second line\n", to: url)

  let content = try String(contentsOf: url, encoding: .utf8)
  #expect(content == "first line\nsecond line\n")
}

@Test func appendTrimsPastCapKeepingNewestCompleteLines() throws {
  let url = tempURL("synclog-trim", ext: "log")
  defer { try? FileManager.default.removeItem(at: url) }

  // Fill well past a tiny cap, then confirm the file was cut to the newest half,
  // starts on a line boundary, and still ends with the newest line.
  for i in 0..<100 {
    SyncLog.append("line \(i) padded to be reasonably long for the test\n", to: url, cap: 1024)
  }

  let data = try Data(contentsOf: url)
  #expect(data.count <= 1024)

  let content = try #require(String(data: data, encoding: .utf8))
  #expect(content.hasPrefix("line "))          // cut on a line boundary, no partial head
  #expect(content.hasSuffix("line 99 padded to be reasonably long for the test\n"))
}

@Test func appendBelowCapNeverTrims() throws {
  let url = tempURL("synclog-nocap", ext: "log")
  defer { try? FileManager.default.removeItem(at: url) }

  SyncLog.append("a\n", to: url, cap: 1024)
  SyncLog.append("b\n", to: url, cap: 1024)

  #expect(try String(contentsOf: url, encoding: .utf8) == "a\nb\n")
}
