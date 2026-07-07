import ArgumentParser
import PensieveKit

struct AddNode: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "add-node",
    abstract: "Create a node (domain, concept, initiative, …).")
  @Argument var name: String
  @Option var kind: String = NodeKind.concept
  @Option var parent: String?
  @Option var description: String = ""
  func run() throws {
    let created = try NodeCommands.add(try openCanonical(), name: name, kind: kind,
                                       parent: parent, description: description)
    print(created != nil ? "added \(kind) '\(name)'" : "unknown parent '\(parent ?? "")'")
  }
}
