import ArgumentParser
import PensieveKit

struct ListProjects: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "list",
    abstract: "List the node tree (strands nested under their projects).")
  func run() throws {
    let nodes = try ProjectQueries.all(try openCanonical())
    for line in NodeTree.render(nodes) { print(line) }
  }
}
