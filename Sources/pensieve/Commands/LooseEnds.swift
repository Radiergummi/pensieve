import ArgumentParser
import Foundation
import PensieveKit

struct LooseEnds: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "looseends",
    abstract: "List open, cited loose ends (quote-first).")
  @Flag(name: .long) var all = false
  @Argument var project: String?

  func validate() throws {
    if all, project != nil {
      throw ValidationError("Pass a project name or --all, not both.")
    }
  }

  func run() throws {
    let db = try openCanonical()
    var nodeID: UUID? = nil
    if let project {   // validate() guarantees --all is not also set
      guard let p = try ProjectQueries.status(db, name: project, limit: 0)?.project else {
        print("no project named '\(project)'"); return
      }
      nodeID = p.id
    }
    let ends = try LooseEndQueries.open(db, nodeID: nodeID, now: Date())
    for v in ends {
      print("\u{201C}\(v.looseEnd.quote)\u{201D}")
      print("  \u{21B3} \(v.looseEnd.text)  [\(v.looseEnd.role), \(v.ageDays)d]")
    }
    print("\n\(ends.count) open loose end(s)")
  }
}
