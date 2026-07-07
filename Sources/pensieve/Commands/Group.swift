import ArgumentParser
import PensieveKit
import SQLiteData

struct Group: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "group",
    abstract: "Merge one or more projects into the first.")
  @Argument var names: [String]
  func run() throws {
    guard names.count >= 2 else {
      print("group needs at least two project names: the target followed by one or more to merge into it")
      return
    }
    let db = try openCanonical()
    let projects = try ProjectQueries.all(db)
    let ids = names.compactMap { name in projects.first { $0.name == name }?.id }
    guard let primary = ids.first, ids.count == names.count else {
      print("unknown project name(s)"); return
    }
    try ProjectResolver(db: db).group(primary, into: Array(ids.dropFirst()))
    print("grouped \(names.dropFirst().joined(separator: ", ")) into \(names[0])")
  }
}
