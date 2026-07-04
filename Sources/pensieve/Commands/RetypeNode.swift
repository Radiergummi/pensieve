import ArgumentParser
import PensieveKit

struct RetypeNode: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "retype",
    abstract: "Change a node's kind.")
  @Argument var node: String
  @Argument var newKind: String
  func run() throws {
    let ok = try NodeCommands.retype(try openCanonical(), node: node, to: newKind)
    print(ok ? "retyped \(node) → \(newKind)" : "unknown node '\(node)'")
  }
}
