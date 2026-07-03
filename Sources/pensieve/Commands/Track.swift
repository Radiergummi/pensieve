import ArgumentParser
import Foundation
import PensieveKit

struct Track: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "track",
    abstract: "Explicitly register a repo as a project.")
  @Argument var path: String
  func run() throws {
    let abs = URL(fileURLWithPath: path).standardizedFileURL.path
    let r = try ProjectResolver(db: try openCanonical()).resolve(path: abs, kind: "gitRepo")
    print("tracking \(r.project.name)")
  }
}
