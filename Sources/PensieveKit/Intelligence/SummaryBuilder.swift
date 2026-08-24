import Foundation
import SQLiteData

public struct ProjectSummary: Sendable {
  public let whatItIs: String
  public let lastWorkDone: String
  public let looseEnds: [LooseEndView]
}

public struct SummaryBuilder: Sendable {
  private let provider: any LLMProvider
  public init(provider: any LLMProvider) { self.provider = provider }

  /// Total char budget for the narrator's fact sheet. `narrate`/`build` feed this to a single
  /// un-chunked `complete`; replacing terse lines with real `workSummary` prose can balloon it
  /// and overflow the window (→ narration vanishes). Bound it: include recent events until the
  /// budget is hit.
  public static let factSheetBudget = 1800

  /// How many of a node's most recent events any narration path may look at. **One number, because
  /// the narration cache key is derived from exactly these events.**
  ///
  /// It was three numbers. `SummaryBuilder.build` asked `ProjectQueries.status` for 15 and
  /// `factLines` took `prefix(15)`; `SessionContextQueries.bundle` defaulted `recentLimit` to 8. The
  /// key is `NarrationCacheKey.make(events: status.recentEvents, …)`, so the app wrote entries keyed
  /// on 15 events and `pensieve prime` / `pensieve mcp` looked up keys built from 8 — a lookup that
  /// could never hit. The hook that exists to hand a session warm context was therefore permanently
  /// cold, and on a miss it also narrated a different, shorter window than the app had.
  ///
  /// 15 rather than 8 because 15 is the number with a measurement behind it: `factLines`' own
  /// comment records that all 36 nodes whose recent 15 events are entirely generated labels have no
  /// narratable event anywhere in their history. The 8 was an unexamined default.
  public static let narratableEventWindow = 15

  /// The single definition of what an event contributes to a fact sheet — or `nil` when it
  /// contributes nothing a recap could honestly be built from.
  ///
  /// The rule is structural, not textual, because Pensieve writes these `summary` strings itself:
  /// `Ingester` gives a `git.commit` the commit subject (real content, line 104), a `git.checkout`
  /// the string `"checkout <branch>"` (line 121) and a `cc.session` the string
  /// `"session (N prompts)"` (line 168). The latter two are labels generated from a branch name and
  /// a count — honest as labels, but not facts about the work. Handing them to the narrator produced
  /// recaps like *"The sessions included 41, 54, 107, 41, 349, 28, and 410, and 1 prompts"*: the
  /// model narrating, faithfully, a fact sheet that contained no facts.
  ///
  /// So an event is narratable iff it carries a real `workSummary`, or its terse `summary` is itself
  /// content (`git.commit` only). Note this is a test of *content*, not of kind — a checkout that
  /// somehow gained a `workSummary` is narratable, because the content is what matters.
  ///
  /// `EmbeddableCorpus.gather` already drops `git.checkout` for the search corpus on the same
  /// reasoning; this brings the narrator's input in line with it.
  public static func narratableContent(for event: Event) -> String? {
    if let work = event.workSummary, !work.isEmpty { return work }
    return event.kind == CaptureKind.gitCommit ? event.summary : nil
  }

  /// Deterministic fact sheet the model is allowed to narrate — and nothing beyond it. Built from
  /// each event's `narratableContent`, so events that carry only a generated label contribute
  /// nothing and an all-label node yields a sheet with no activity lines at all.
  public static func assembleFacts(project: Node, events: [Event]) -> String {
    factSheet(project: project, lines: factLines(events: events))
  }

  /// The narratable activity lines, newest first — the shared source of truth for both the fact
  /// sheet and the "is there anything to narrate at all" guard, so the two can never disagree
  /// about the same event window.
  ///
  /// The recency window is applied BEFORE filtering, deliberately: this is "last work done", so a
  /// node whose recent history is all labels must not have its recap backfilled from months ago.
  /// Measured on the live store, that costs nothing — all 36 nodes whose recent 15 events are
  /// entirely labels have zero narratable events anywhere in their history.
  ///
  /// Filtered events do not consume `factSheetBudget`; only what is actually narrated competes
  /// for it.
  private static func factLines(events: [Event]) -> [String] {
    var lines: [String] = []
    var used = 0
    for event in events.prefix(Self.narratableEventWindow) {
      guard let content = narratableContent(for: event) else { continue }
      let line = "- \(event.kind): \(content)"
      if used + line.count > factSheetBudget, !lines.isEmpty { break }
      lines.append(line)
      used += line.count
    }
    return lines
  }

  private static func factSheet(project: Node, lines: [String]) -> String {
    "Project: \(project.name)\nRecent activity:\n\(lines.joined(separator: "\n"))"
  }

  /// The single constrained narration prompt — shared by `build` and `narrate` so the wording
  /// can't drift between them.
  private static func makePrompt(facts: String) -> String {
    """
    Narrate ONLY the facts below into 2-3 sentences of "last work done". Do NOT add any \
    fact, plan, or detail that is not explicitly present. If the facts are thin, say so.

    \(facts)
    """
  }

  public func build(_ database: any DatabaseWriter, node: Node, now: Date) async throws -> ProjectSummary? {
    // Key off the node the caller holds — NOT its name. Node names aren't unique (two distinct
    // repos can share a basename), so a name lookup would resolve an arbitrary same-named node
    // and, e.g., narrate an empty one while the real one's activity stays invisible.
    let status = try ProjectQueries.status(database, node: node, limit: Self.narratableEventWindow)
    // Nothing captured for this node (e.g. a scanned-but-untouched git repo): skip it rather
    // than hand the model an empty fact sheet, which it "narrates" by hallucinating or echoing
    // the prompt. A loose end can't exist without a source event, so no events ⇒ nothing grounded.
    guard !status.recentEvents.isEmpty else { return nil }
    // Events exist but none of them says anything (only generated labels): nothing to narrate, so
    // skip rather than spend a call producing a restatement of the labels. Symmetric with `narrate`.
    let lines = Self.factLines(events: status.recentEvents)
    guard !lines.isEmpty else { return nil }
    let facts = Self.factSheet(project: status.project, lines: lines)
    let narration = (try? await provider.complete(prompt: Self.makePrompt(facts: facts))) ?? facts   // fall back to raw facts
    let ends = try LooseEndQueries.open(database, nodeID: status.project.id, now: now)
    return ProjectSummary(
      whatItIs: "\(status.project.name) — \(status.project.state.rawValue)",
      lastWorkDone: narration,
      looseEnds: ends)
  }

  /// Best-effort prose recap of the given events. Returns nil when there's nothing to narrate
  /// (no events) OR the provider fails/returns empty — never substitutes the raw fact sheet, so a
  /// caller can show a narration section only on a genuine result. Takes events directly (no DB
  /// re-query) so the prose narrates exactly what the caller already displays.
  public func narrate(project: Node, events: [Event]) async -> String? {
    guard !events.isEmpty else { return nil }
    // No narratable content ⇒ return nil BEFORE the provider call. The fact sheet would otherwise
    // consist of generated labels, and the model would faithfully narrate them into a facts-dump.
    let lines = Self.factLines(events: events)
    guard !lines.isEmpty else { return nil }
    let facts = Self.factSheet(project: project, lines: lines)
    guard let raw = try? await provider.complete(prompt: Self.makePrompt(facts: facts)) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
