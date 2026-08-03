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
    let database = try openCanonical()
    var nodeID: UUID?
    if let project {   // validate() guarantees --all is not also set
      guard let projectNode = try ProjectQueries.status(database, name: project, limit: 0)?.project else {
        print("no project named '\(project)'"); return
      }
      nodeID = projectNode.id
    }
    let ends = try LooseEndQueries.open(database, nodeID: nodeID, now: Date())
    for looseEndView in ends {
      print("\u{201C}\(looseEndView.looseEnd.quote)\u{201D}")
      print("  \u{21B3} \(looseEndView.looseEnd.text)  [\(looseEndView.looseEnd.role), \(looseEndView.ageDays)d]")
    }
    print("\n\(ends.count) open loose end(s)")
  }
}
