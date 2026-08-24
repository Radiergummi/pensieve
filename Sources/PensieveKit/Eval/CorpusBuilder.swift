// Sources/PensieveKit/Eval/CorpusBuilder.swift
import Foundation
import SQLiteData

/// Marker Claude Code stamps on a compaction-summary record in the raw transcript JSONL.
/// Not preserved by `TranscriptParser`'s per-message shape, so detected on the raw file text.
private let compactionMarker = "\"isCompactSummary\":true"

public enum CorpusBuilder {
  /// The task folders the corpus is pooled, written and reloaded under.
  ///
  /// An enum rather than a `[String]` because the comment this replaced named a hazard it could not
  /// enforce: *"`decodeFrozenItem` must carry a case for every entry: a folder listed here with no
  /// decoder loads nothing, just as silently."* The folder names were spelled three times — this
  /// list, `decodeFrozenItem`'s switch, and `taskFolder(for:)`'s switch — with a `default: return nil`
  /// absorbing any disagreement. Adding a fourth task therefore compiled, wrote its items to disk,
  /// and loaded **zero** of them back, while `TaskRegistry.consistency` reported the registry as
  /// consistent because the folder *was* listed.
  ///
  /// Switching over this enum exhaustively (no `default:`) turns that into a compile error.
  public enum Task: String, CaseIterable, Sendable {
    case extraction, narration, description
  }

  /// The folder names, for the callers that genuinely want strings (`TaskRegistry.consistency`
  /// compares them against task ids, which are strings on the `EvalTask` protocol).
  public static let taskFolders = Task.allCases.map(\.rawValue)

  /// Reads the canonical store (+ transcripts/git) and produces a frozen, stratified corpus for
  /// all tasks. Read-only against the DB; never crashes on an empty store (0 nodes/sources ⇒
  /// empty pools ⇒ `([], manifest-with-zero-counts)`).
  public static func build(database: any DatabaseReader, projectsDir: URL, config: EvalConfig) throws -> ([CorpusItem], CorpusManifest) {
    let narrationPool = try buildNarrationPool(database: database)
    let extractionPool = buildExtractionPool(projectsDir: projectsDir)
    let descriptionPool = try buildDescriptionPool(database: database)

    let narrationItems = CorpusSampler.select(from: narrationPool, size: config.corpusSize, seed: config.corpusSeed)
    let extractionItems = CorpusSampler.select(from: extractionPool, size: config.corpusSize, seed: config.corpusSeed)
    let descriptionItems = CorpusSampler.select(from: descriptionPool, size: config.corpusSize, seed: config.corpusSeed)
    let allItems = narrationItems + extractionItems + descriptionItems

    let stressItems = (narrationPool + extractionPool + descriptionPool)
      .filter { $0.isStress }.map { $0.item.id }

    let sortedForHash = allItems.sorted { $0.id < $1.id }
    let parts = try sortedForHash.map { try serialize($0) }
    let manifest = CorpusManifest(
      seed: config.corpusSeed, contentHash: CorpusHash.hash(parts),
      counts: ["narration": narrationItems.count, "extraction": extractionItems.count, "description": descriptionItems.count],
      stressItems: stressItems)
    return (allItems, manifest)
  }

  /// Writes each item to `<directory>/<task>/<id>.json` (clearing prior per-task subdirectories
  /// first) and the manifest to `<directory>/manifest.json`.
  public static func write(_ items: [CorpusItem], manifest: CorpusManifest, to directory: URL) throws {
    let fileManager = FileManager.default
    for task in Task.allCases {
      let taskDir = directory.appendingPathComponent(task.rawValue)
      try? fileManager.removeItem(at: taskDir)
      try fileManager.createDirectory(at: taskDir, withIntermediateDirectories: true)
    }
    for item in items {
      let taskDir = directory.appendingPathComponent(taskFolder(for: item).rawValue)
      let data = try serialize(item)
      try data.write(to: taskDir.appendingPathComponent("\(item.id).json"))
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
  }

  /// Reads back a previously-written corpus. Missing/unreadable per-task directories or files
  /// are skipped rather than thrown — a partially-frozen or never-sampled corpus degrades to
  /// however many items are actually on disk (possibly zero).
  public static func loadFrozen(from directory: URL) -> [CorpusItem] {
    let fileManager = FileManager.default
    var items: [CorpusItem] = []
    for task in Task.allCases {
      let taskDir = directory.appendingPathComponent(task.rawValue)
      guard let files = try? fileManager.contentsOfDirectory(at: taskDir, includingPropertiesForKeys: nil) else { continue }
      for file in files where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file) else { continue }
        if let item = decodeFrozenItem(task: task, data: data) { items.append(item) }
      }
    }
    return items
  }

  /// Exhaustive over `Task` on purpose — no `default:`. A new corpus task is now a compile error
  /// here rather than a folder whose items silently fail to load.
  private static func decodeFrozenItem(task: Task, data: Data) -> CorpusItem? {
    switch task {
    case .extraction:
      guard let extractionItem = try? JSONDecoder().decode(ExtractionCorpusItem.self, from: data) else { return nil }
      return .extraction(extractionItem)
    case .narration:
      guard let narrationItem = try? JSONDecoder().decode(NarrationCorpusItem.self, from: data) else { return nil }
      return .narration(narrationItem)
    case .description:
      guard let descriptionItem = try? JSONDecoder().decode(DescriptionCorpusItem.self, from: data) else { return nil }
      return .description(descriptionItem)
    }
  }

  // MARK: - Narration pool (active nodes with events; the emptiest node is the stress case)

  /// ONE read transaction for the nodes and all their events, not one per node. Not only cheaper:
  /// a frozen corpus is supposed to be a snapshot, and a per-node transaction let an ingest between
  /// two of them put node A's events before a drain and node B's after it — so the "frozen" corpus
  /// described a store state that never existed at any single instant.
  private static func buildNarrationPool(database: any DatabaseReader) throws -> [PoolEntry<CorpusItem>] {
    let withEvents: [(node: Node, events: [Event])] = try database.read { database in
      try Node.where { $0.state.eq(NodeState.active) }.fetchAll(database).map { node in
        (node, try Event.where { $0.nodeID.eq(node.id) }
          .order { $0.occurredAt.desc() }.limit(60).fetchAll(database))
      }
    }
    guard !withEvents.isEmpty else { return [] }

    // The emptiest node (fewest events, ties broken by id for determinism) is the stress case —
    // it exercises narration's "no/near-no events" degrade-to-nil path.
    let stress = withEvents.min { lhs, rhs in
      lhs.events.count != rhs.events.count ? lhs.events.count < rhs.events.count : lhs.node.id.uuidString < rhs.node.id.uuidString
    }

    var pool: [PoolEntry<CorpusItem>] = []
    for entry in withEvents {
      let isStressEntry = entry.node.id == stress?.node.id
      guard isStressEntry || !entry.events.isEmpty else { continue }   // only the stress slot may carry 0 events
      let item = CorpusItem.narration(NarrationCorpusItem(
        id: entry.node.id.uuidString, nodeName: entry.node.name, events: entry.events.map(EventDTO.init)))
      let strata = isStressEntry ? "narration.stress" : (entry.events.count >= 8 ? "narration.long" : "narration.short")
      pool.append(PoolEntry(strata: strata, isStress: isStressEntry, item: item))
    }
    return pool
  }

  // MARK: - Extraction pool (parsed transcripts; longest + one compacted session are stress cases)

  private static func buildExtractionPool(projectsDir: URL) -> [PoolEntry<CorpusItem>] {
    let files = TranscriptDiscovery.discover(
      projectsDir: projectsDir, now: Date(), ageBound: 3650 * 24 * 60 * 60, alreadyIngested: { _ in false })

    struct Candidate { let id: String; let parsed: ParsedSession; let isCompacted: Bool }
    var candidates: [Candidate] = []
    for file in files {
      let parsed = TranscriptParser.parse(fileURL: file)
      guard !parsed.messages.isEmpty else { continue }
      let raw = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
      candidates.append(Candidate(id: parsed.sessionID, parsed: parsed, isCompacted: raw.contains(compactionMarker)))
    }
    guard !candidates.isEmpty else { return [] }

    let longest = candidates.max { $0.parsed.messages.count < $1.parsed.messages.count }
    let compacted = candidates.first { $0.isCompacted }

    func shape(_ candidate: Candidate) -> String {
      if candidate.isCompacted { return "compacted" }
      return candidate.parsed.messages.count >= 40 ? "long" : "short"
    }
    func item(_ candidate: Candidate) -> CorpusItem {
      .extraction(ExtractionCorpusItem(id: candidate.id, shape: shape(candidate), messages: candidate.parsed.messages.map(TranscriptMessageDTO.init)))
    }

    var pool: [PoolEntry<CorpusItem>] = []
    for candidate in candidates where candidate.id != longest?.id && candidate.id != compacted?.id {
      pool.append(PoolEntry(strata: shape(candidate), isStress: false, item: item(candidate)))
    }
    if let longest { pool.append(PoolEntry(strata: "extraction.stress", isStress: true, item: item(longest))) }
    if let compacted, compacted.id != longest?.id {
      pool.append(PoolEntry(strata: "extraction.stress", isStress: true, item: item(compacted)))
    }
    return pool
  }

  // MARK: - Description pool (nodes whose sole source is a git repo)

  private static func buildDescriptionPool(database: any DatabaseReader) throws -> [PoolEntry<CorpusItem>] {
    let sources = try database.read { database in try Source.all.fetchAll(database) }
    let byNode = Dictionary(grouping: sources, by: { $0.nodeID })
    var pool: [PoolEntry<CorpusItem>] = []
    for (nodeID, nodeSources) in byNode {
      guard nodeSources.count == 1, let only = nodeSources.first, only.kind == SourceKind.gitRepo else { continue }
      let context = ProjectContext.gather(commonDir: only.key)
      let item = CorpusItem.description(DescriptionCorpusItem(id: nodeID.uuidString, context: ProjectContextDTO(context)))
      pool.append(PoolEntry(strata: "description", isStress: false, item: item))
    }
    return pool
  }

  // MARK: - Serialization

  /// The third site that used to spell the folder names. Returns the `Task` so the name itself is
  /// stated once, on the enum.
  private static func taskFolder(for item: CorpusItem) -> Task {
    switch item {
    case .extraction: return .extraction
    case .narration: return .narration
    case .description: return .description
    }
  }

  private static func serialize(_ item: CorpusItem) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    switch item {
    case .extraction(let extractionItem): return try encoder.encode(extractionItem)
    case .narration(let narrationItem): return try encoder.encode(narrationItem)
    case .description(let descriptionItem): return try encoder.encode(descriptionItem)
    }
  }
}
