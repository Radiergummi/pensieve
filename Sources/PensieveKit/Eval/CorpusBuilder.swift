// Sources/PensieveKit/Eval/CorpusBuilder.swift
import Foundation
import SQLiteData

/// Marker Claude Code stamps on a compaction-summary record in the raw transcript JSONL.
/// Not preserved by `TranscriptParser`'s per-message shape, so detected on the raw file text.
private let compactionMarker = "\"isCompactSummary\":true"

public enum CorpusBuilder {
  /// Reads the canonical store (+ transcripts/git) and produces a frozen, stratified corpus for
  /// all tasks. Read-only against the DB; never crashes on an empty store (0 nodes/sources ⇒
  /// empty pools ⇒ `([], manifest-with-zero-counts)`).
  public static func build(db: any DatabaseReader, projectsDir: URL, config: EvalConfig) throws -> ([CorpusItem], CorpusManifest) {
    let narrationPool = try buildNarrationPool(db: db)
    let extractionPool = buildExtractionPool(projectsDir: projectsDir)
    let descriptionPool = try buildDescriptionPool(db: db)

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

  /// Writes each item to `<dir>/<task>/<id>.json` (clearing prior per-task subdirectories first)
  /// and the manifest to `<dir>/manifest.json`.
  public static func write(_ items: [CorpusItem], manifest: CorpusManifest, to dir: URL) throws {
    let fm = FileManager.default
    for task in ["extraction", "narration", "description"] {
      let taskDir = dir.appendingPathComponent(task)
      try? fm.removeItem(at: taskDir)
      try fm.createDirectory(at: taskDir, withIntermediateDirectories: true)
    }
    for item in items {
      let taskDir = dir.appendingPathComponent(taskFolder(for: item))
      let data = try serialize(item)
      try data.write(to: taskDir.appendingPathComponent("\(item.id).json"))
    }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
  }

  /// Reads back a previously-written corpus. Missing/unreadable per-task directories or files
  /// are skipped rather than thrown — a partially-frozen or never-sampled corpus degrades to
  /// however many items are actually on disk (possibly zero).
  public static func loadFrozen(from dir: URL) -> [CorpusItem] {
    let fm = FileManager.default
    var items: [CorpusItem] = []
    for task in ["extraction", "narration", "description"] {
      let taskDir = dir.appendingPathComponent(task)
      guard let files = try? fm.contentsOfDirectory(at: taskDir, includingPropertiesForKeys: nil) else { continue }
      for file in files where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file) else { continue }
        switch task {
        case "extraction":
          if let e = try? JSONDecoder().decode(ExtractionCorpusItem.self, from: data) { items.append(.extraction(e)) }
        case "narration":
          if let n = try? JSONDecoder().decode(NarrationCorpusItem.self, from: data) { items.append(.narration(n)) }
        case "description":
          if let d = try? JSONDecoder().decode(DescriptionCorpusItem.self, from: data) { items.append(.description(d)) }
        default: break
        }
      }
    }
    return items
  }

  // MARK: - Narration pool (active nodes with events; the emptiest node is the stress case)

  private static func buildNarrationPool(db: any DatabaseReader) throws -> [(strata: String, isStress: Bool, item: CorpusItem)] {
    let activeNodes = try db.read { db in try Node.where { $0.state.eq(NodeState.active) }.fetchAll(db) }
    var withEvents: [(node: Node, events: [Event])] = []
    for node in activeNodes {
      let events = try db.read { db in
        try Event.where { $0.nodeID.eq(node.id) }.order { $0.occurredAt.desc() }.limit(60).fetchAll(db)
      }
      withEvents.append((node, events))
    }
    guard !withEvents.isEmpty else { return [] }

    // The emptiest node (fewest events, ties broken by id for determinism) is the stress case —
    // it exercises narration's "no/near-no events" degrade-to-nil path.
    let stress = withEvents.min { a, b in
      a.events.count != b.events.count ? a.events.count < b.events.count : a.node.id.uuidString < b.node.id.uuidString
    }

    var pool: [(strata: String, isStress: Bool, item: CorpusItem)] = []
    for entry in withEvents {
      let isStressEntry = entry.node.id == stress?.node.id
      guard isStressEntry || !entry.events.isEmpty else { continue }   // only the stress slot may carry 0 events
      let item = CorpusItem.narration(NarrationCorpusItem(
        id: entry.node.id.uuidString, nodeName: entry.node.name, events: entry.events.map(EventDTO.init)))
      let strata = isStressEntry ? "narration.stress" : (entry.events.count >= 8 ? "narration.long" : "narration.short")
      pool.append((strata, isStressEntry, item))
    }
    return pool
  }

  // MARK: - Extraction pool (parsed transcripts; longest + one compacted session are stress cases)

  private static func buildExtractionPool(projectsDir: URL) -> [(strata: String, isStress: Bool, item: CorpusItem)] {
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

    func shape(_ c: Candidate) -> String {
      if c.isCompacted { return "compacted" }
      return c.parsed.messages.count >= 40 ? "long" : "short"
    }
    func item(_ c: Candidate) -> CorpusItem {
      .extraction(ExtractionCorpusItem(id: c.id, shape: shape(c), messages: c.parsed.messages.map(TranscriptMessageDTO.init)))
    }

    var pool: [(strata: String, isStress: Bool, item: CorpusItem)] = []
    for c in candidates where c.id != longest?.id && c.id != compacted?.id {
      pool.append((shape(c), false, item(c)))
    }
    if let longest { pool.append(("extraction.stress", true, item(longest))) }
    if let compacted, compacted.id != longest?.id { pool.append(("extraction.stress", true, item(compacted))) }
    return pool
  }

  // MARK: - Description pool (nodes whose sole source is a git repo)

  private static func buildDescriptionPool(db: any DatabaseReader) throws -> [(strata: String, isStress: Bool, item: CorpusItem)] {
    let sources = try db.read { db in try Source.all.fetchAll(db) }
    let byNode = Dictionary(grouping: sources, by: { $0.nodeID })
    var pool: [(strata: String, isStress: Bool, item: CorpusItem)] = []
    for (nodeID, nodeSources) in byNode {
      guard nodeSources.count == 1, let only = nodeSources.first, only.kind == SourceKind.gitRepo else { continue }
      let ctx = ProjectContext.gather(commonDir: only.key)
      let item = CorpusItem.description(DescriptionCorpusItem(id: nodeID.uuidString, context: ProjectContextDTO(ctx)))
      pool.append(("description", false, item))
    }
    return pool
  }

  // MARK: - Serialization

  private static func taskFolder(for item: CorpusItem) -> String {
    switch item {
    case .extraction: return "extraction"
    case .narration: return "narration"
    case .description: return "description"
    }
  }

  private static func serialize(_ item: CorpusItem) throws -> Data {
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    switch item {
    case .extraction(let e): return try enc.encode(e)
    case .narration(let n): return try enc.encode(n)
    case .description(let d): return try enc.encode(d)
    }
  }
}
