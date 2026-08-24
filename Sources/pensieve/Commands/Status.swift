import ArgumentParser
import Foundation
import PensieveKit

struct Status: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "status")
  @Argument var project: String
  func run() throws {
    let database = try openCanonical()
    guard let status = try ProjectQueries.status(database, name: project, limit: 20) else {
      throw CommandFailure("no project named '\(project)'")
    }
    print("# \(status.project.name)")
    // ISO-8601, not the raw `Date` description: `print(someDate)` renders a locale-independent but
    // unlabelled "2026-08-24 09:15:00 +0000", which is neither what a human reads nor what a script
    // parses. `sync` already timestamps its output this way.
    for event in status.recentEvents {
      print("  \(event.occurredAt.ISO8601Format()) \(event.kind)  \(event.summary)")
    }
    let openLooseEnds = try LooseEndQueries.open(database, nodeID: status.project.id, now: Date())
    guard !openLooseEnds.isEmpty else { return }
    print("\n## Open loose ends (\(openLooseEnds.count))")
    for view in openLooseEnds { printLooseEnd(view, indent: "  ") }
  }
}
