import ArgumentParser
import PensieveKit

struct Nest: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "nest",
    abstract: "Move a node under a new parent.")
  @Argument var child: String
  @Option(name: .long) var under: String
  func run() throws {
    let succeeded = try NodeCommands.nest(try openCanonical(), child: child, under: under)
    print(succeeded ? "nested \(child) under \(under)" : "unknown node name(s)")
  }
}
