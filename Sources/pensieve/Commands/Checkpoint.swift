import ArgumentParser
import PensieveKit

struct Checkpoint: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "checkpoint",
    abstract: "Record a manual 'I was in the middle of X' note on a project.")
  @Argument var project: String
  @Argument var note: String
  func run() throws {
    let ok = try CheckpointCommands.add(try openCanonical(), projectName: project, note: note)
    print(ok ? "noted on \(project)" : "no project named '\(project)'")
  }
}
