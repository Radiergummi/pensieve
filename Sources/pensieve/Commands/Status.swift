import ArgumentParser
import Foundation
import PensieveKit

struct Status: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "status")
  @Argument var project: String
  func run() throws {
    let database = try openCanonical()
    guard let status = try ProjectQueries.status(database, name: project, limit: 20) else {
      print("no project named '\(project)'"); return
    }
    print("# \(status.project.name)")
    for event in status.recentEvents { print("  \(event.occurredAt) \(event.kind)  \(event.summary)") }
    let ends = try LooseEndQueries.open(database, nodeID: status.project.id, now: Date())
    guard !ends.isEmpty else { return }
    print("\n## Open loose ends (\(ends.count))")
    for looseEndView in ends {
      print("  \u{201C}\(looseEndView.looseEnd.quote)\u{201D}")                        // quote-first: the authoritative line
      // paraphrase is secondary
      print("    \u{21B3} \(looseEndView.looseEnd.text)  [\(looseEndView.looseEnd.role), \(looseEndView.ageDays)d]")
    }
  }
}
