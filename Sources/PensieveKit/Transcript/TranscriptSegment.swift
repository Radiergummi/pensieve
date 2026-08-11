import Foundation

/// One rendering unit of a transcript message. Every case carries `raw` — the exact source
/// substring it came from — which is what makes the no-loss invariant (I2) an executable property
/// test rather than an aspiration: `segments.map(\.raw).joined() == input`.
public enum TranscriptSegment: Equatable, Sendable {
  case markdown(String)
  case callout(TranscriptCallout)
  case harness(HarnessBlock)

  /// The exact source text this segment was parsed from.
  public var raw: String {
    switch self {
    case .markdown(let markdownString): return markdownString
    case .callout(let callout): return callout.raw
    case .harness(let harnessBlock): return harnessBlock.raw
    }
  }
}

/// A paired ALL-CAPS tag (`<HARD-GATE>…</HARD-GATE>`) — an emphasis envelope, rendered as a
/// severity-tinted block.
public struct TranscriptCallout: Equatable, Sendable {
  public let severity: CalloutSeverity
  /// Verbatim tag name, e.g. "HARD-GATE". **Content — never localized.**
  public let tagName: String
  /// The callout's interior, as markdown. Harness tags inside are NOT recursively parsed (I5).
  public let body: String
  public let raw: String

  public init(severity: CalloutSeverity, tagName: String, body: String, raw: String) {
    self.severity = severity; self.tagName = tagName; self.body = body; self.raw = raw
  }
}

/// Closed set → the labels are localizable chrome.
///
/// **Three cases, not six.** Parser-visible corpus counts justify no more: `HARD-GATE` 154,
/// `SUBAGENT-STOP` 1, `EXTREMELY-IMPORTANT` 1, everything else 0. `.warning` folds into `.caution`
/// (same visual register), `.tip`/`.note` into `.neutral`. Growing this enum later is additive and
/// every exhaustive `switch` becomes a compile error until handled — so grow it on evidence.
public enum CalloutSeverity: String, Equatable, Sendable {
  case caution, important, neutral

  private static let cautionTokens: Set<String> =
    ["STOP", "GATE", "CRITICAL", "DANGER", "NEVER", "WARNING", "CAUTION"]
  private static let importantTokens: Set<String> = ["IMPORTANT", "MUST", "REQUIRED"]

  /// Maps a tag name to a severity by splitting on `-`/`_` and matching **whole tokens**.
  /// Substring matching would mis-fire: `GATE` inside `AUTHGW`, `STOP` inside `NONSTOP`.
  /// Precedence is caution → important → neutral; first match wins.
  public static func forTagName(_ name: String) -> CalloutSeverity {
    let tokens = Set(
      name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.uppercased() })
    if !tokens.isDisjoint(with: cautionTokens) { return .caution }
    if !tokens.isDisjoint(with: importantTokens) { return .important }
    return .neutral
  }
}

/// A machine envelope — the harness talking, not a person. A struct wrapping a kind enum so every
/// case gets `raw` without threading it through each associated-value list.
public struct HarnessBlock: Equatable, Sendable {
  public let kind: HarnessKind
  public let raw: String

  public init(kind: HarnessKind, raw: String) { self.kind = kind; self.raw = raw }
}

public enum HarnessKind: Equatable, Sendable {
  case command(name: String, message: String?, args: String?)
  case taskNotification(TaskNotificationBlock)
  case systemReminder(String)
  case commandCaveat(String)
  /// `local-command-stdout` / `local-command-stderr`.
  case commandOutput(String)
  case bashIO(input: String?, output: String?)
  case toolUses(String)
  case toolUseError(String)
  /// "[Request interrupted…"
  case interrupted
  /// "Base directory for this skill: <path>"
  case skillPreamble(path: String)
  /// An allowlisted tag whose children we don't model.
  case unknown(tag: String, body: String)
}

/// `<task-notification>`'s modelled children. Children are recognised **only inside** a matched
/// task-notification span, never at top level — `<summary>` appears 958 times against
/// task-notification's 969, i.e. it is overwhelmingly a child, but at top level it is ordinary HTML.
public struct TaskNotificationBlock: Equatable, Sendable {
  public let taskID: String?
  public let toolUseID: String?
  public let outputFile: String?
  public let status: String?
  public let summary: String?
  public let note: String?
  /// Nothing is silently dropped: unmodelled children land here.
  public let unrecognisedChildren: [String: String]

  public init(taskID: String? = nil, toolUseID: String? = nil, outputFile: String? = nil,
              status: String? = nil, summary: String? = nil, note: String? = nil,
              unrecognisedChildren: [String: String] = [:]) {
    self.taskID = taskID; self.toolUseID = toolUseID; self.outputFile = outputFile
    self.status = status; self.summary = summary; self.note = note
    self.unrecognisedChildren = unrecognisedChildren
  }
}

extension HarnessKind {
  /// Content — verbatim, never localized. nil when the label alone says everything.
  ///
  /// Lives in Kit rather than beside the view because it is also the FINDABLE projection of a
  /// harness block: find must index exactly what the card renders, and two copies of this would
  /// drift into highlighting text that isn't on screen.
  public var displayBody: String? {
    switch self {
    case .command(let name, let message, let args):
      return [name, message, args].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    case .taskNotification(let taskNotification):
      return [taskNotification.summary, taskNotification.status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    case .systemReminder(let segment), .commandCaveat(let segment), .commandOutput(let segment),
         .toolUses(let segment), .toolUseError(let segment):
      return segment
    case .bashIO(let input, let output):
      return [input, output].compactMap { $0 }.joined(separator: "\n")
    case .skillPreamble(let path):
      return path
    case .interrupted:
      return nil
    case .unknown(_, let body):
      return body
    }
  }
}

extension TranscriptSegment {
  /// The text a find should search for this segment — **what the app displays**, never `raw`.
  ///
  /// `raw` is the exact source substring, pinned by the no-loss property, and includes tag markup
  /// plus `unrecognisedChildren` that no view renders. Indexing it would produce matches in
  /// invisible bytes and inflate the count. nil when the segment renders no body at all.
  public var findableText: String? {
    switch self {
    case .markdown(let text):
      return text.isEmpty ? nil : text
    case .callout(let callout):
      // The tagName renders as chrome beside a localized severity label, not as prose.
      return callout.body.isEmpty ? nil : callout.body
    case .harness(let block):
      guard let body = block.kind.displayBody, !body.isEmpty else { return nil }
      return body
    }
  }
}
