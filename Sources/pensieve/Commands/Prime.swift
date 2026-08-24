import ArgumentParser
import Foundation
import PensieveKit

struct Prime: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "prime",
    abstract: "SessionStart hook: emit the cwd's grounded Pensieve context (reads hook JSON from stdin).")

  private struct HookInput: Decodable { let cwd: String? }

  func run() async throws {
    // Read the hook's cwd from stdin; fall back to the process cwd. Never fail a session — every
    // exit from here is 0 on purpose, because a non-zero SessionStart hook is a broken session.
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let cwd = (try? JSONDecoder().decode(HookInput.self, from: data))?.cwd
      ?? FileManager.default.currentDirectoryPath
    guard let database = try? openCanonicalReadOnly() else { return }
    // `narrating: false` → cache-READ-ONLY: never narrates, never spawns, never blocks.
    // `try?` on a `-> ProjectContextBundle?` yields a double optional; `?? nil` flattens it so
    // both a thrown error and an unbound cwd (nil bundle) emit nothing.
    let result = try? await SessionContextQueries.bundle(
      forPath: cwd, nodeID: nil, database, now: Date(),
      narration: cliNarrationOptions(narrating: false))
    guard let bundle = result ?? nil else { return }
    print(SessionContextRender.compact(bundle))
  }
}
