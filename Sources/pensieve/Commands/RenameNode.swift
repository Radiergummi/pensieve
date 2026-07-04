import ArgumentParser
import PensieveKit

struct RenameNode: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "rename",
    abstract: "Rename a node.")
  @Argument var node: String
  @Argument var newName: String
  func run() throws {
    let ok = try NodeCommands.rename(try openCanonical(), node: node, to: newName)
    print(ok ? "renamed to \(newName)" : "unknown node '\(node)'")
  }
}
