import ArgumentParser
import PensieveKit

struct Nest: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "nest",
    abstract: "Move a node under a new parent.")
  @Argument var child: String
  @Option(name: .long) var under: String
  func run() throws {
    guard try NodeCommands.nest(try openCanonical(), child: child, under: under) else {
      // `nest` also returns false for a cycle-forming move, which the old "unknown node name(s)"
      // misreported as a lookup failure.
      throw CommandFailure("could not nest '\(child)' under '\(under)' — unknown node, "
        + "or the move would create a cycle")
    }
    print("nested \(child) under \(under)")
  }
}
