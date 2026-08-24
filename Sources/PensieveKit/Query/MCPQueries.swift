import Foundation
import SQLiteData

/// The derivation behind the MCP server's four tools and two resources: store resolution, scope
/// construction, the passage budget, and payload assembly. Everything except the protocol plumbing.
///
/// It lived in `Sources/pensieve/Commands/Mcp.swift` until the 2026-08-24 sweep — the one CLI file
/// out of 28 that was not thin — where `PensieveKitTests` could not reach a line of it. The CLI now
/// holds only the tool schemas, argument-to-request decoding and `CallTool.Result` wrapping.
///
/// Each public entry point opens the canonical store read-only per call, so the server binds lazily
/// once the store exists (a single pool's per-read transactions would already see the latest
/// committed drain). The paired internal overload takes an already-open reader and is what the tests
/// drive.
public enum MCPQueries {
  /// Built once for the process (the MCP server is long-lived): the index pool open is otherwise
  /// repeated on every `search` call. The server is session-scoped and the app/daemon own rebuilds.
  private static let searchStore = SearchIndexStore(url: PensievePaths.searchIndexURL())

  // MARK: - Store resolution

  /// The canonical store, read-only — or nil when it has never been created.
  ///
  /// Throws `MCPFailure.canonicalStoreUnreadable` when the file is *there* and will not open. A bare
  /// `try?` collapsed those two into one, so a corrupt, locked or permission-denied store was
  /// answered with the same empty payload as a fresh machine: MCP told the model no work had ever
  /// been captured. `MonitorSnapshot.gather` already draws this distinction; this is the same rule.
  static func openCanonicalIfPresent(at url: URL) throws -> (any DatabaseReader)? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      return try openCanonicalDatabaseReadOnly(at: url)
    } catch {
      Log.sync.error("""
        MCP: canonical store exists but would not open at \(url.path, privacy: .public): \
        \(error, privacy: .public)
        """)
      throw MCPFailure.canonicalStoreUnreadable(path: url.path)
    }
  }

  private static func openCanonical() throws -> (any DatabaseReader)? {
    try openCanonicalIfPresent(at: resolvedCanonicalURL())
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  // MARK: - project_context

  public static func projectContextJSON(_ request: MCPProjectContextRequest,
                                        narration: NarrationOptions) async throws -> Data {
    guard let database = try openCanonical() else {
      return try makeEncoder().encode(Optional<ProjectContextBundle>.none)   // "null"
    }
    return try await projectContextJSON(request, narration: narration, database)
  }

  static func projectContextJSON(_ request: MCPProjectContextRequest, narration: NarrationOptions,
                                 now: Date = Date(),
                                 _ database: any DatabaseReader) async throws -> Data {
    // The cwd is the zero-argument default: "reload wherever I am". A rejected `node_id` never
    // reaches here — the request type refuses to decode one — so this can no longer silently answer
    // for a different project than the caller named.
    let effectivePath = request.path ?? FileManager.default.currentDirectoryPath
    let bundle = try await SessionContextQueries.bundle(
      forPath: effectivePath, nodeID: request.nodeID, database, now: now, narration: narration)
    return try makeEncoder().encode(bundle)   // encodes `null` for an unbound path
  }

  /// The `pensieve://node/{id}` resource. Shares `SessionContextQueries.bundle` with the
  /// `project_context` tool, so the two can never describe the same node differently.
  public static func nodeMarkdown(id: UUID, narration: NarrationOptions) async throws -> String? {
    guard let database = try openCanonical() else { return nil }
    return try await nodeMarkdown(id: id, narration: narration, database)
  }

  static func nodeMarkdown(id: UUID, narration: NarrationOptions, now: Date = Date(),
                           _ database: any DatabaseReader) async throws -> String? {
    guard let bundle = try await SessionContextQueries.bundle(
      forPath: nil, nodeID: id, database, now: now, narration: narration) else { return nil }
    return SessionContextRender.markdown(bundle)
  }

  // MARK: - whats_next

  public static func whatsNextJSON(_ request: MCPWhatsNextRequest) throws -> Data {
    guard let database = try openCanonical() else {
      return try makeEncoder().encode([WhatsNextItem]())   // "[]"
    }
    return try whatsNextJSON(request, database)
  }

  static func whatsNextJSON(_ request: MCPWhatsNextRequest, now: Date = Date(),
                            _ database: any DatabaseReader) throws -> Data {
    let items = try SessionContextQueries.rankedContext(limit: request.limit, context: request.context,
                                                       database, now: now)
    return try makeEncoder().encode(items)
  }

  /// The `pensieve://smartlist/whatsNext` resource. Ten rows: a resource is read whole, so it is not
  /// bounded by the tool's `limit`.
  public static func whatsNextMarkdown() throws -> String {
    guard let database = try openCanonical() else { return SessionContextRender.whatsNext([]) }
    return try whatsNextMarkdown(database)
  }

  static let markdownResourceLimit = 10

  static func whatsNextMarkdown(now: Date = Date(), _ database: any DatabaseReader) throws -> String {
    let items = try SessionContextQueries.rankedContext(limit: markdownResourceLimit, context: nil,
                                                       database, now: now)
    return SessionContextRender.whatsNext(items)
  }

  // MARK: - recall

  public static func recallJSON(_ request: MCPRecallRequest) throws -> Data {
    guard let database = try openCanonical() else {
      return try makeEncoder().encode(Optional<RecallBundle>.none)   // "null"
    }
    return try recallJSON(request, database)
  }

  /// `loose_end_id` wins when both are given. The request type guarantees at least one is present.
  static func recallJSON(_ request: MCPRecallRequest, _ database: any DatabaseReader) throws -> Data {
    let bundle: RecallBundle?
    if let looseEndID = request.looseEndID {
      bundle = try SessionContextQueries.recall(looseEndID: looseEndID, radius: request.radius, database)
    } else if let passageID = request.passageID {
      bundle = try SessionContextQueries.recall(passageID: passageID, radius: request.radius, database)
    } else {
      bundle = nil
    }
    return try makeEncoder().encode(bundle)   // encodes `null` for an unknown id
  }

  // MARK: - search

  /// Unified "find across my work": BM25 over the on-device FTS5 index, the only retrieval path.
  /// Cloud is never used here; the index is on-device only.
  public static func searchJSON(_ request: MCPSearchRequest) throws -> Data {
    guard let database = try openCanonical() else {
      return try makeEncoder().encode(MCPSearchPayload(items: [], indexState: .absent))
    }
    return try searchJSON(request, store: searchStore, database)
  }

  /// Every node a search may surface, as ids.
  ///
  /// MCP has no Focus context, so the scope is the whole store narrowed by the one searchable-state
  /// rule — `NodeState.isSearchable`, which the index's SQL filter and `SearchHitResolver` also
  /// apply. The flag must gate this half too: leaving it active-only would filter archived hits back
  /// out after the query layer had already allowed them through.
  static func searchableNodeIDs(includeArchived: Bool,
                                _ database: any DatabaseReader) throws -> Set<UUID> {
    try database.read { database in
      Set(try Node.all.fetchAll(database)
        .filter { $0.state.isSearchable(includeArchived: includeArchived) }
        .map(\.id))
    }
  }

  /// `include_archived` widens BOTH node state and loose-end status, matching the app's single scope
  /// bar. The kernel keeps the two dimensions separate; conflating them is the caller's choice, and
  /// this is the caller.
  static func searchScope(_ request: MCPSearchRequest,
                          _ database: any DatabaseReader) throws -> SearchScope {
    SearchScope(visibleNodeIDs: try searchableNodeIDs(includeArchived: request.includeArchived, database),
                limit: request.limit,
                includeArchived: request.includeArchived,
                includeClosed: request.includeArchived)
  }

  /// Passages get their own, smaller budget rather than sharing `limit`.
  ///
  /// Two lists in one array cannot both mean "at most `limit`" — and capping the concatenation
  /// instead would delete the passage list entirely whenever the ranked list is already full, which
  /// is the common case. Half, floored at two, keeps the conversation list present without letting it
  /// dominate the page. Derived from the ranked scope (not the raw request) so the two cannot drift.
  static func passageScope(from scope: SearchScope) -> SearchScope {
    SearchScope(visibleNodeIDs: scope.visibleNodeIDs, limit: max(2, scope.limit / 2),
                includeArchived: scope.includeArchived, includeClosed: scope.includeClosed)
  }

  static func searchJSON(_ request: MCPSearchRequest, store: SearchIndexStore,
                         _ database: any DatabaseReader) throws -> Data {
    let scope = try searchScope(request, database)
    let ranked = SearchQueries.search(query: request.query, file: request.file, scope: scope,
                                      store: store, database)
    // `limit` is honoured by SearchQueries itself; there is no second engine to make room for, so
    // the payload does not over-allocate and then truncate.
    let items = ranked.map { MCPSearchItem(hit: $0) }
    // Appended, never interleaved: passage scores come from a different FTS5 table with a different
    // average document length, exactly like path hits. The array order is the contract the tool
    // description states, and this preserves it.
    //
    // Same `file` as the ranked half. A passage can never satisfy a path restriction, so this
    // narrows the conversation list to nothing whenever one is set — which is the point: one array
    // whose two halves answered different questions is worse than a shorter, coherent one.
    let passages = PassageQueries.search(query: request.query, file: request.file,
                                         scope: passageScope(from: scope), store: store, database)
    return try makeEncoder().encode(
      MCPSearchPayload(items: items + passages.map { MCPSearchItem(passage: $0) },
                       indexState: store.state()))
  }
}
