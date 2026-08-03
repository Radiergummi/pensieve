import ArgumentParser
import Foundation
import PensieveKit

/// Offline salience bootstrap. Default: pre-label the unlabeled open backlog with Haiku (writes
/// labelSuggestion only). `--import`: fold prior hand-adjudicated labels into the human `label`.
struct LabelSuggest: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "label-suggest",
    abstract: "Pre-label open loose ends with Haiku (suggestion only), or import hand-labels.")

  @Option(name: .long, help: "Import human labels from a JSON file of {quote, salient} instead of suggesting.")
  var `import`: String?

  @Option(name: .long, help: "Cap the number of loose ends suggested in this run.")
  var limit: Int?

  @Flag(name: .long, help: "Re-suggest loose ends that already have a suggestion.")
  var force: Bool = false

  @Option(name: .long, help: "Model for the suggestion pass (claude -p).")
  var model: String = "claude-haiku-4-5-20251001"

  func run() async throws {
    let database = try openCanonical()

    if let path = `import` {
      let entries = try Self.decodeLabels(at: path)
      let result = try LooseEndCommands.importLabels(database, entries)
      print("Imported: \(result.matched) matched, \(result.skipped) skipped (no matching quote).")
      return
    }

    let modelName = model
    let provider = ClaudeCLIProvider(run: { try Self.claudeRun($0, model: modelName) })
    let s = try await SalienceSuggester(provider: provider).run(database, limit: limit, force: force)
    print("""
    Suggested \(s.suggested)/\(s.candidates) candidates: \(s.salient) salient / \(s.noise) noise \
    (\(s.quoteOnly) quote-only, \(s.skipped) skipped on provider error).
    """)
  }

  /// A JSON `[{ "quote": String, "salient": Bool }]` → (quote, label) entries.
  static func decodeLabels(at path: String) throws -> [(quote: String, label: String)] {
    struct Entry: Decodable { let quote: String; let salient: Bool }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode([Entry].self, from: data).map {
      (quote: $0.quote, label: $0.salient ? LooseEndLabel.salient : LooseEndLabel.noise)
    }
  }

  /// Wall-clock cap on a single `claude -p` invocation, mirroring `ClaudeCLIProvider.shellRun`: a
  /// hung child is terminated and the call throws rather than stalling the sequential batch run.
  static let timeout: TimeInterval = 120

  /// Runs `claude -p --model <model>` with the prompt on stdin; trimmed stdout. Mirrors the eval
  /// harness's helper (salience prompts are small, so writing stdin before draining can't deadlock).
  static func claudeRun(_ prompt: String, model: String) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["claude", "-p", "--model", model]
    let stdin = Pipe(), stdout = Pipe()
    p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
    try p.run()
    DispatchQueue.global().async {
      try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
      try? stdin.fileHandleForWriting.close()
    }
    nonisolated(unsafe) var outData = Data()
    let ioGroup = DispatchGroup()
    ioGroup.enter()
    DispatchQueue.global().async {
      outData = stdout.fileHandleForReading.readDataToEndOfFile(); ioGroup.leave()
    }
    if ioGroup.wait(timeout: .now() + timeout) == .timedOut {
      p.terminate()
      _ = ioGroup.wait(timeout: .now() + 5)
      throw LLMError.providerFailed("claude -p timed out after \(Int(timeout))s")
    }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw LLMError.providerFailed("claude -p exit \(p.terminationStatus)") }
    return String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
