import Foundation
import SQLiteData

/// A small, deterministic world for the app's XCUITest suite to launch against.
///
/// It lives here rather than in the test target because a wrong fixture is invisible: the UI tests
/// above it stay green while asserting against the wrong world. `UITestFixtureTests` pins its shape.
///
/// Every date is an offset from an injected `now` so relative labels ("vor 3 Stunden") and dormancy
/// buckets are stable across runs. UUIDs are fixed so tests and `pensieve://` deep links can address
/// nodes directly.
public enum UITestFixture {
  /// Fixed node ids. Named `Identifiers` rather than the plan's `ID`, which is two characters and so
  /// fails `type_name` — and reads as an abbreviation, which this project's naming rule forbids.
  public enum Identifiers {
    public static let workDomain = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    public static let colibri = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    public static let colibriStrand = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
    public static let dormantProject = UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!
    public static let archivedProject = UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!
    public static let personalProject = UUID(uuidString: "00000000-0000-0000-0000-0000000000A6")!
  }

  public static let colibriOpenLooseEndText = "Decide whether the parser keeps the retry shim"
  public static let colibriOpenLooseEndQuote =
    "we should probably decide whether the parser keeps the retry shim before shipping"

  /// Split into `makeNodes`/`makeEvents`/`makeLooseEnds` rather than one body: the plan's single
  /// function ran to 59 lines against `function_body_length`'s 50.
  public static func seed(canonicalAt url: URL, now: Date) throws {
    let database = try openCanonicalDatabase(at: url)

    let nodes = makeNodes(now: now)
    let colibriSource = Source(nodeID: Identifiers.colibri, kind: SourceKind.gitRepo,
                               key: "/tmp/fixture/colibri")
    let dormantSource = Source(nodeID: Identifiers.dormantProject, kind: SourceKind.gitRepo,
                               key: "/tmp/fixture/countries")
    let events = makeEvents(now: now, colibriSource: colibriSource, dormantSource: dormantSource)
    let looseEnds = makeLooseEnds(now: now, sessionEvent: events.session, dormantEvent: events.dormantCommit)

    try database.write { database in
      for node in nodes { try Node.insert { node }.execute(database) }
      for source in [colibriSource, dormantSource] { try Source.insert { source }.execute(database) }
      for event in events.all { try Event.insert { event }.execute(database) }
      for looseEnd in looseEnds { try LooseEnd.insert { looseEnd }.execute(database) }
    }
  }

  private static func makeNodes(now: Date) -> [Node] {
    [
      Node(id: Identifiers.workDomain, name: "Work", state: .active,
           createdAt: now.addingTimeInterval(-90 * 86_400), parentID: nil, kind: .domain,
           description: "Everything paid for", context: "work"),
      Node(id: Identifiers.colibri, name: "Colibri", state: .active,
           createdAt: now.addingTimeInterval(-60 * 86_400), parentID: Identifiers.workDomain,
           kind: .project, description: "Hummingbird ingest pipeline"),
      Node(id: Identifiers.colibriStrand, name: "retry-shim", state: .active,
           createdAt: now.addingTimeInterval(-5 * 86_400), parentID: Identifiers.colibri,
           kind: .strand, description: "", branchKey: "retry-shim"),
      Node(id: Identifiers.dormantProject, name: "Countries List", state: .active,
           createdAt: now.addingTimeInterval(-120 * 86_400), parentID: nil, kind: .project,
           description: "Static reference data"),
      Node(id: Identifiers.archivedProject, name: "Old Prototype", state: .archived,
           createdAt: now.addingTimeInterval(-200 * 86_400), parentID: nil, kind: .project,
           description: "Superseded"),
      Node(id: Identifiers.personalProject, name: "Sourdough Log", state: .active,
           createdAt: now.addingTimeInterval(-30 * 86_400), parentID: nil, kind: .project,
           description: "Weekend baking", context: "personal"),
    ]
  }

  /// A named struct rather than a 3-tuple, which trips `large_tuple` (max 2 members).
  private struct FixtureEvents {
    let session: Event
    let recentCommit: Event
    let dormantCommit: Event
    var all: [Event] { [session, recentCommit, dormantCommit] }
  }

  private static func makeEvents(now: Date, colibriSource: Source,
                                 dormantSource: Source) -> FixtureEvents {
    let session = Event(
      nodeID: Identifiers.colibri, sourceID: colibriSource.id,
      occurredAt: now.addingTimeInterval(-2 * 3600), kind: CaptureKind.ccSession,
      summary: "session (5 prompts)", detailJSON: #"{"files":["Sources/Parser.swift"]}"#
    )
    let recentCommit = Event(
      nodeID: Identifiers.colibriStrand, sourceID: colibriSource.id,
      occurredAt: now.addingTimeInterval(-3 * 86_400), kind: CaptureKind.gitCommit,
      summary: "fix: drop the retry shim's dead branch",
      detailJSON: #"{"files":["Sources/Parser.swift"]}"#
    )
    let dormantCommit = Event(
      nodeID: Identifiers.dormantProject, sourceID: dormantSource.id,
      occurredAt: now.addingTimeInterval(-40 * 86_400), kind: CaptureKind.gitCommit,
      summary: "chore: refresh ISO codes", detailJSON: #"{"files":["data/iso.json"]}"#
    )
    return FixtureEvents(session: session, recentCommit: recentCommit, dormantCommit: dormantCommit)
  }

  /// `label` is left unset on every open end on purpose: `LooseEnd.isOpen` is
  /// `status == .open AND label != "noise"`, so a `noise` label would silently make one invisible.
  private static func makeLooseEnds(now: Date, sessionEvent: Event, dormantEvent: Event) -> [LooseEnd] {
    [
      LooseEnd(nodeID: Identifiers.colibri, sourceEventID: sessionEvent.id,
               text: colibriOpenLooseEndText, quote: colibriOpenLooseEndQuote,
               status: .open, role: "user", sourceMessageIndex: 4),
      LooseEnd(nodeID: Identifiers.colibri, sourceEventID: sessionEvent.id,
               text: "Check the ingest watermark after the shim change",
               quote: "and check the ingest watermark after that change lands",
               status: .open, role: "user", sourceMessageIndex: 9),
      LooseEnd(nodeID: Identifiers.dormantProject, sourceEventID: dormantEvent.id,
               text: "Verify the ISO refresh against the upstream list",
               quote: "verify the ISO refresh against the upstream list at some point",
               status: .open, role: "user", sourceMessageIndex: 2),
      LooseEnd(nodeID: Identifiers.colibri, sourceEventID: sessionEvent.id,
               text: "Rename the parser fixture directory",
               quote: "we should rename that parser fixture directory",
               status: .done, role: "user", sourceMessageIndex: 12,
               resolvedAt: now.addingTimeInterval(-6 * 3600)),
    ]
  }
}
