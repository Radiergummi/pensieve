import ArgumentParser
import PensieveKit

struct Status: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "status")
  @Argument var project: String
  func run() throws {
    guard let s = try ProjectQueries.status(try openCanonical(), name: project, limit: 20) else {
      print("no project named '\(project)'"); return
    }
    print("# \(s.project.name)")
    for e in s.recentEvents { print("  \(e.occurredAt) \(e.kind)  \(e.summary)") }
  }
}
