import ArgumentParser
import PensieveKit

struct RenameNode: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "rename",
    abstract: "Rename a node.")
  @Argument var node: String
  @Argument var newName: String
  func run() throws {
    guard try NodeCommands.rename(try openCanonical(), node: node, to: newName) else {
      throw CommandFailure("unknown node '\(node)'")
    }
    print("renamed to \(newName)")
  }
}
