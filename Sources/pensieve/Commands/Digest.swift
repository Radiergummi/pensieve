import ArgumentParser
import Foundation
import PensieveKit

struct Digest: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "digest",
    abstract: "Generate a morning markdown digest across active projects.")
  func run() async throws {
    let database = try openCanonical()
    let builder = SummaryBuilder(provider: makeDefaultLLMProvider(defaults: PensieveDefaults.shared()))
    print("# Pensieve digest\n")
    // Active projects only, matching the abstract (archived/muted don't belong in a morning digest).
    for project in try ProjectQueries.all(database) where project.state == .active {
      guard let sum = try await builder.build(database, node: project, now: Date()) else { continue }
      print("## \(sum.whatItIs)")
      print("\n_\(sum.lastWorkDone)_  <!-- generated narration -->\n")   // fenced: clearly generated
      if !sum.looseEnds.isEmpty {
        print("**Open loose ends (cited):**")
        for looseEndView in sum.looseEnds { print("- \u{201C}\(looseEndView.looseEnd.quote)\u{201D} (\(looseEndView.ageDays)d)") }
      }
      print("")
    }
  }
}
