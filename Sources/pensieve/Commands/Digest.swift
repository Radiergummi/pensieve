import ArgumentParser
import Foundation
import PensieveKit

struct Digest: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "digest",
    abstract: "Generate a morning markdown digest across active projects.")
  func run() async throws {
    let db = try openCanonical()
    let builder = SummaryBuilder(provider: makeDefaultLLMProvider())
    print("# Pensieve digest\n")
    for p in try ProjectQueries.all(db) {
      guard let sum = try await builder.build(db, projectName: p.name, now: Date()) else { continue }
      print("## \(sum.whatItIs)")
      print("\n_\(sum.lastWorkDone)_  <!-- generated narration -->\n")   // fenced: clearly generated
      if !sum.looseEnds.isEmpty {
        print("**Open loose ends (cited):**")
        for v in sum.looseEnds { print("- \u{201C}\(v.looseEnd.quote)\u{201D} (\(v.ageDays)d)") }
      }
      print("")
    }
  }
}
