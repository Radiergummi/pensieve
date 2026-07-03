import ArgumentParser
import Foundation
import PensieveKit

struct Next: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "next",
    abstract: "Ranked queue of what to pick up, on grounded signals only.")
  func run() throws {
    for item in try NextQueries.ranked(try openCanonical(), now: Date()) {
      print("\(item.project.name)  — \(item.openLooseEnds) loose end(s), \(item.daysDormant)d dormant")
    }
  }
}
