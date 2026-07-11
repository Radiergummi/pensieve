import Testing
import Foundation
@testable import PensieveKit

@Test func shippedConfigHasBarsForEveryTask() throws {
  let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("eval-config.json")
  let cfg = try EvalConfig.load(from: url)
  #expect(TaskRegistry.consistencyProblems(config: cfg).isEmpty)
}
