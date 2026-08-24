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
      throw ValidationError("unknown kind '\(kind)' "
        + "(expected one of: \(NodeKind.all.map(\.rawValue).joined(separator: ", ")))")
    }
    guard try NodeCommands.add(try openCanonical(), name: name, kind: nodeKind,
                               parent: parent, description: description) != nil else {
      throw CommandFailure("unknown parent '\(parent ?? "")'")
    }
    print("added \(kind) '\(name)'")
  }
}
