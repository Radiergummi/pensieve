import ArgumentParser
import Foundation
import PensieveKit
import SQLiteData

struct Prime: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "prime",
    abstract: "SessionStart hook: emit the cwd's grounded Pensieve context (reads hook JSON from stdin).")

  private struct HookInput: Decodable { let cwd: String? }

  func run() async throws {
    // Read the hook's cwd from stdin; fall back to the process cwd. Never fail a session.
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let cwd = (try? JSONDecoder().decode(HookInput.self, from: data))?.cwd
      ?? FileManager.default.currentDirectoryPath
    guard let db = try? openCanonicalReadOnly() else { return }
    let providerKind = resolvedProviderKind(defaults: PensieveDefaults.shared(), cloudConfig: nil, apiKey: nil)
    let cache = NarrationCache(url: PensievePaths.narrationCacheURL())
    // Cache-READ-ONLY: summaryBuilder nil → never narrates, never spawns, never blocks.
    // `try?` on a `-> ProjectContextBundle?` yields a double optional; `?? nil` flattens it so
    // both a thrown error and an unbound cwd (nil bundle) emit nothing.
    let result = try? await SessionContextQueries.bundle(
      forPath: cwd, nodeID: nil, db, now: Date(),
      summaryBuilder: nil, providerKind: providerKind, cache: cache)
    guard let bundle = result ?? nil else { return }
    print(SessionContextRender.compact(bundle))
  }
}
