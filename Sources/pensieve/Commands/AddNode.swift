import ArgumentParser
import PensieveKit

struct AddNode: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "add-node",
    abstract: "Create a node (domain, concept, initiative, …).")
  @Argument var name: String
  @Option var kind: String = NodeKind.concept.rawValue
  @Option var parent: String?
  @Option var description: String = ""
  func run() throws {
    guard let nodeKind = NodeKind(rawValue: kind) else {
      print("unknown kind '\(kind)' (expected one of: \(NodeKind.all.map(\.rawValue).joined(separator: ", ")))")
      return
    }
    let created = try NodeCommands.add(try openCanonical(), name: name, kind: nodeKind,
                                       parent: parent, description: description)
    print(created != nil ? "added \(kind) '\(name)'" : "unknown parent '\(parent ?? "")'")
  }
}
