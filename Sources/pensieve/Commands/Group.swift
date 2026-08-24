import ArgumentParser
import PensieveKit
import SQLiteData

struct Group: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "group",
    abstract: "Merge one or more nodes into the first.")
  @Argument var names: [String]

  func validate() throws {
    guard names.count >= 2 else {
      throw ValidationError("group needs at least two nodes: the target followed by one or more to merge into it")
    }
  }

  func run() throws {
    let database = try openCanonical()
    // `NodeCommands.find` rather than a local name match over `ProjectQueries.all`: it accepts a
    // UUID as well as an exact name, which every sibling command already did — so `pensieve group
    // <uuid>` used to be the one verb that rejected an id the app and MCP hand out.
    let resolved = try database.read { database in
      try names.map { name in (name: name, nodeID: try NodeCommands.find(database, nameOrID: name)?.id) }
    }
    let unknown = resolved.filter { $0.nodeID == nil }.map(\.name)
    guard unknown.isEmpty else {
      throw CommandFailure("unknown node(s): \(unknown.joined(separator: ", "))")
    }
    let nodeIDs = resolved.compactMap(\.nodeID)
    try ProjectResolver(database: database).group(nodeIDs[0], into: Array(nodeIDs.dropFirst()))
    print("grouped \(names.dropFirst().joined(separator: ", ")) into \(names[0])")
  }
}
