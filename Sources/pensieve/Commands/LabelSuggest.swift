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

    // The shared provider, not a local spawn: it carries the cwd pin. An unpinned `claude -p`
    // inherits this command's cwd — a real project directory, since `label-suggest` is run from a
    // terminal inside one — becomes a Claude Code session there, is captured by the SessionEnd hook
    // and is re-ingested as work. One bootstrap run over the backlog is one phantom session per
    // batch, all attributed to whatever repo you were standing in.
    let provider = ClaudeCLIProvider(model: model)
    let result = try await SalienceSuggester(provider: provider).run(database, limit: limit, force: force)
    print("""
    Suggested \(result.suggested)/\(result.candidates) candidates: \(result.salient) salient / \(result.noise) noise \
    (\(result.quoteOnly) quote-only, \(result.skipped) skipped on provider error).
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
}
