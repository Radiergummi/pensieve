import ArgumentParser
import Foundation
import PensieveKit

struct Status: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "status")
  @Argument var project: String
  func run() throws {
    let database = try openCanonical()
    guard let s = try ProjectQueries.status(database, name: project, limit: 20) else {
      print("no project named '\(project)'"); return
    }
    print("# \(s.project.name)")
    for e in s.recentEvents { print("  \(e.occurredAt) \(e.kind)  \(e.summary)") }
    let ends = try LooseEndQueries.open(database, nodeID: s.project.id, now: Date())
    guard !ends.isEmpty else { return }
    print("\n## Open loose ends (\(ends.count))")
    for v in ends {
      print("  \u{201C}\(v.looseEnd.quote)\u{201D}")                        // quote-first: the authoritative line
      print("    \u{21B3} \(v.looseEnd.text)  [\(v.looseEnd.role), \(v.ageDays)d]")  // paraphrase is secondary
    }
  }
}
