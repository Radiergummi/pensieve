import Foundation
import SQLiteData

/// A loose end's resolved provenance: the surrounding-transcript window AND its parsed segments,
/// parallel to `context.messages`.
public struct LoadedProvenance: Sendable {
  public let context: ProvenanceContext
  /// One segment array per message in `context.messages`, same order. Shared with the view so the
  /// find document's segment ordinals and the rendered ordinals are the same numbers.
  public let segments: [[TranscriptSegment]]
}

/// Resolves provenance for loose ends, parsing each transcript at most once.
///
/// Two things it fixes at once: the sweep needs every loose end's window without parsing a 3 MB
/// JSONL per loose end, and the shipped row-expansion path re-parses the same file once per expanded
/// row. Both go through here.
public actor ProvenanceLoader {
  private let database: any DatabaseReader
  private let parse: @Sendable (URL) -> ParsedSession
  private let cacheLimit: Int

  /// A cached window, plus the file fingerprint it was sliced from. Live sessions GROW, so an entry
  /// is only served while its transcript's `(size, mtime)` is unchanged — the app's `refreshToken`
  /// would not do: it never bumps on the FSEvents watch path (`AppModel.swift:98-99`), i.e. exactly
  /// the growing-live-session case would have gone stale until ⌘R.
  private struct Entry {
    let loaded: LoadedProvenance
    let fingerprint: Fingerprint?
    var lastUsed: Int
  }

  private struct Fingerprint: Equatable {
    let size: Int
    let modified: Date
  }

  private var cache: [UUID: Entry] = [:]
  private var clock = 0

  public init(database: any DatabaseReader, cacheLimit: Int = 200) {
    self.init(database: database, cacheLimit: cacheLimit, parse: TranscriptParser.parse(fileURL:))
  }

  init(database: any DatabaseReader, cacheLimit: Int = 200,
       parse: @escaping @Sendable (URL) -> ParsedSession) {
    self.database = database
    self.cacheLimit = cacheLimit
    self.parse = parse
  }

  public func load(_ looseEnd: LooseEnd) async -> LoadedProvenance? {
    await load(all: [looseEnd], onProgress: { _, _ in })[looseEnd.id]
  }

  /// Loads every loose end's provenance, grouped by transcript path so each file is parsed once.
  /// `onProgress` reports `(pathsDone, pathsTotal)` for the find bar.
  public func load(all looseEnds: [LooseEnd],
                   onProgress: @Sendable (Int, Int) -> Void) async -> [UUID: LoadedProvenance] {
    var result: [UUID: LoadedProvenance] = [:]
    var pending: [LooseEnd] = []
    for looseEnd in looseEnds {
      if let cached = validEntry(for: looseEnd.id) {
        result[looseEnd.id] = cached
      } else {
        pending.append(looseEnd)
      }
    }
    guard !pending.isEmpty else {
      onProgress(0, 0)
      return result
    }

    let eventsByID = await resolveEvents(for: pending)
    let byPath = groupByPath(pending, eventsByID: eventsByID, into: &result)

    let paths = byPath.keys.sorted()
    onProgress(0, paths.count)
    for (index, path) in paths.enumerated() {
      if Task.isCancelled { return result }
      for (looseEndID, loaded) in loadPath(path, group: byPath[path] ?? []) {
        result[looseEndID] = loaded
      }
      onProgress(index + 1, paths.count)
    }
    return result
  }

  /// Resolves every pending loose end's source event in ONE read.
  private func resolveEvents(for pending: [LooseEnd]) async -> [UUID: Event] {
    let eventIDs = Set(pending.map(\.sourceEventID))
    let events = (try? await database.read { database in
      try eventIDs.map { eventID in
        try Event.where { $0.id.eq(eventID) }.fetchOne(database)
      }.compactMap { $0 }
    }) ?? []
    return Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
  }

  /// Groups pending loose ends by transcript path. A loose end whose event has no resolvable
  /// transcript path is stored+resolved immediately (into `result`) rather than grouped.
  private func groupByPath(_ pending: [LooseEnd], eventsByID: [UUID: Event],
                           into result: inout [UUID: LoadedProvenance])
    -> [String: [(looseEnd: LooseEnd, event: Event)]] {
    var byPath: [String: [(looseEnd: LooseEnd, event: Event)]] = [:]
    for looseEnd in pending {
      guard let event = eventsByID[looseEnd.sourceEventID] else { continue }
      guard let path = ProvenanceQueries.transcriptPath(in: event) else {
        let loaded = LoadedProvenance(context: unavailable(looseEnd, event), segments: [])
        store(looseEnd.id, loaded, fingerprint: nil)
        result[looseEnd.id] = loaded
        continue
      }
      byPath[path, default: []].append((looseEnd, event))
    }
    return byPath
  }

  /// Resolves every loose end sharing one transcript `path`, parsing it AT MOST once (never, if the
  /// file is gone). Stores each result in the cache and returns it keyed by loose-end ID.
  private func loadPath(_ path: String,
                        group: [(looseEnd: LooseEnd, event: Event)]) -> [UUID: LoadedProvenance] {
    var results: [UUID: LoadedProvenance] = [:]
    let fingerprint = self.fingerprint(ofPath: path)
    guard let fingerprint else {
      // Gone: a stat, never a parse. 24 of 37 referenced transcripts are in this state.
      for item in group {
        let loaded = LoadedProvenance(context: unavailable(item.looseEnd, item.event), segments: [])
        store(item.looseEnd.id, loaded, fingerprint: nil)
        results[item.looseEnd.id] = loaded
      }
      return results
    }
    let session = parse(URL(fileURLWithPath: path))
    for item in group {
      let context = ProvenanceQueries.context(session: session, looseEnd: item.looseEnd, event: item.event)
      let segments = context.messages.map { TranscriptMarkup.parse($0.text) }
      let loaded = LoadedProvenance(context: context, segments: segments)
      store(item.looseEnd.id, loaded, fingerprint: fingerprint)
      results[item.looseEnd.id] = loaded
    }
    // The ParsedSession goes out of scope here: TranscriptParser builds each message's text as an
    // independent String, so the non-windowed messages are genuinely released.
    return results
  }

  private func validEntry(for looseEndID: UUID) -> LoadedProvenance? {
    guard var entry = cache[looseEndID] else { return nil }
    if let fingerprint = entry.fingerprint {
      guard let path = ProvenanceQueries.transcriptPath(in: entry.loaded.context.sourceEvent),
            self.fingerprint(ofPath: path) == fingerprint
      else { cache[looseEndID] = nil; return nil }
    }
    clock += 1
    entry.lastUsed = clock
    cache[looseEndID] = entry
    return entry.loaded
  }

  private func store(_ looseEndID: UUID, _ loaded: LoadedProvenance, fingerprint: Fingerprint?) {
    clock += 1
    cache[looseEndID] = Entry(loaded: loaded, fingerprint: fingerprint, lastUsed: clock)
    guard cache.count > cacheLimit else { return }
    let excess = cache.count - cacheLimit
    for (key, _) in cache.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }).prefix(excess) {
      cache[key] = nil
    }
  }

  private func fingerprint(ofPath path: String) -> Fingerprint? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? Int,
          let modified = attributes[.modificationDate] as? Date
    else { return nil }
    return Fingerprint(size: size, modified: modified)
  }

  private func unavailable(_ looseEnd: LooseEnd, _ event: Event) -> ProvenanceContext {
    ProvenanceContext(looseEnd: looseEnd, sourceEvent: event, messages: [],
                      transcriptAvailable: false)
  }
}
