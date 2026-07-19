import ArgumentParser
import PensieveKit

struct RetypeNode: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "retype",
    abstract: "Change a node's kind.")
  @Argument var node: String
  @Argument var newKind: String
  func run() throws {
    guard let kind = NodeKind(rawValue: newKind) else {
      print("unknown kind '\(newKind)' (expected one of: \(NodeKind.all.map(\.rawValue).joined(separator: ", ")))")
      return
    }
    let ok = try NodeCommands.retype(try openCanonical(), node: node, to: kind)
    print(ok ? "retyped \(node) → \(newKind)" : "unknown node '\(node)'")
  }
}
