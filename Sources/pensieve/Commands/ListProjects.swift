import ArgumentParser
import PensieveKit

struct ListProjects: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "list")
  func run() throws {
    for p in try ProjectQueries.all(try openCanonical()) { print("\(p.name)  [\(p.state)]") }
  }
}
