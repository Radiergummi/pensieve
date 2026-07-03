import ArgumentParser
import Foundation
import PensieveKit

struct LooseEnds: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "looseends",
    abstract: "List open, cited loose ends (quote-first).")
  @Flag(name: .long) var all = false
  @Argument var project: String?
  func run() throws {
    let db = try openCanonical()
    var projectID: UUID? = nil
    if let project, !all {
      guard let p = try ProjectQueries.status(db, name: project, limit: 0)?.project else {
        print("no project named '\(project)'"); return
      }
      projectID = p.id
    }
    let ends = try LooseEndQueries.open(db, projectID: projectID, now: Date())
    for v in ends {
      print("\u{201C}\(v.looseEnd.quote)\u{201D}")
      print("  \u{21B3} \(v.looseEnd.text)  [\(v.looseEnd.role), \(v.ageDays)d]")
    }
    print("\n\(ends.count) open loose end(s)")
  }
}
