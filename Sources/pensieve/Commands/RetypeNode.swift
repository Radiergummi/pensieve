import ArgumentParser
import PensieveKit

struct RetypeNode: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "retype",
    abstract: "Change a node's kind.")
  @Argument var node: String
  @Argument var newKind: String
  func run() throws {
    guard let kind = NodeKind(rawValue: newKind) else {
      throw ValidationError("unknown kind '\(newKind)' "
        + "(expected one of: \(NodeKind.all.map(\.rawValue).joined(separator: ", ")))")
    }
    guard try NodeCommands.retype(try openCanonical(), node: node, to: kind) else {
      throw CommandFailure("unknown node '\(node)'")
    }
    print("retyped \(node) → \(newKind)")
  }
}
