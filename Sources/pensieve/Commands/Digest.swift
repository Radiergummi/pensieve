import ArgumentParser
import Foundation
import PensieveKit

struct Digest: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "digest",
    abstract: "Generate a morning markdown digest across active projects.")

  /// Per-run cap on digest narrations — one sequential LLM round-trip each.
  ///
  /// Sibling of the Ingester's `nameRefineCap` / `descriptionRefineCap` / `strandNameCap`, for their
  /// reason: uncapped, a store with ~190 active nodes makes ~190 sequential model calls, so the
  /// command's cost grows with the tree until it is unusable. A node with nothing narratable is FREE
  /// and does not consume a slot — `SummaryBuilder.build` returns nil before it reaches the provider
  /// — exactly like `descriptionRefineCap`'s `.noSignal` candidates.
  static let narrationCap = 20

  func run() async throws {
    let database = try openCanonical()
    let builder = SummaryBuilder(provider: makeDefaultLLMProvider(defaults: PensieveDefaults.shared()))
    print("# Pensieve digest\n")
    // `NextQueries.ranked` rather than `ProjectQueries.all`: it already filters to active nodes and
    // to nodes with captured activity (a node with none narrates to nil anyway), and it orders by the
    // one grounded score the rest of the product ranks by. That ordering is what makes the cap
    // meaningful — capping an unordered fetch would print an arbitrary 20 of 190.
    var narrated = 0
    var skipped = 0
    for item in try NextQueries.ranked(database, now: Date()) {
      guard narrated < Self.narrationCap else { skipped += 1; continue }
      guard let summary = try await builder.build(database, node: item.project, now: Date()) else { continue }
      narrated += 1
      print("## \(summary.whatItIs)")
      print("\n_\(summary.lastWorkDone)_  <!-- generated narration -->\n")   // fenced: clearly generated
      if !summary.looseEnds.isEmpty {
        print("**Open loose ends (cited):**")
        for view in summary.looseEnds { print("- \u{201C}\(view.looseEnd.quote)\u{201D} (\(view.ageDays)d)") }
      }
      print("")
    }
    // Said out loud rather than silently truncated: a digest that quietly stops at 20 reads as
    // "nothing else is active".
    if skipped > 0 { print("_\(skipped) further ranked node(s) not narrated (cap \(Self.narrationCap))._") }
  }
}
