import ArgumentParser
import PensieveKit

// Named `CheckpointCommand`, not `Checkpoint`, to avoid shadowing the PensieveKit
// `Checkpoint` @Table model (different modules, but the bare-name collision is a footgun).
struct CheckpointCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "checkpoint",
    abstract: "Record a manual 'I was in the middle of X' note on a project.")
  @Argument var project: String
  @Argument var note: String
  func run() throws {
    guard try CheckpointCommands.add(try openCanonical(), projectName: project, note: note) else {
      throw CommandFailure("no project named '\(project)'")
    }
    print("noted on \(project)")
  }
}
