// Sources/PensieveApp/NodeMeta.swift
import SwiftUI
import PensieveKit

/// How a node's grounded facts render as text. One place, so the detail header, the middle-column row
/// and the Briefing agree on wording — and on what a node with no captured activity looks like.
///
/// Relative dates carry **no String Catalog key at all**: `.relative(...)` is localized by
/// Foundation. That is the whole point of the Kit carrying a `Date` rather than a day count — see
/// the spec's `%@` vs `%lld` table for what the hand-keyed integer strings did instead.
///
/// The composing members return `String`, not `Text`, because `Text + Text` is deprecated in
/// macOS 26. Joining strings keeps the catalog keys below **byte-identical** to what they were —
/// `Text("…")` and `String(localized: "…")` look up the same key — whereas the deprecation's
/// suggested `Text("\(a)\(b)")` would take a `LocalizedStringKey` and mint a *new* `"%@ · %@"` key
/// over already-localized runs. The app never overrides `\.locale`, so resolving through
/// `Locale.current` here matches what the environment would have resolved.
enum NodeMeta {
  /// The ONE relative-date style this app speaks — "3 weeks ago" / "vor 3 Wochen".
  ///
  /// Five sites wrote `.relative(presentation: .named)` out by hand, and one of them shipped a
  /// `RelativeDateTimeFormatter` with `.abbreviated` units instead, rendering German as "erfasst vor
  /// 2 m" directly above rows reading "vor 3 Tagen". A format style is a value type, so unlike a
  /// shared `ISO8601DateFormatter` there is no shared-mutable-static question to answer.
  static let relativeStyle = Date.RelativeFormatStyle(presentation: .named)

  /// `relativeStyle` applied, for callers joining runs of `String` rather than composing a `Text`.
  static func relative(_ date: Date) -> String { date.formatted(relativeStyle) }

  /// "3 weeks ago" / "vor 3 Wochen". A node with no captured events says so, rather than claiming a
  /// zero it does not have.
  static func recency(_ date: Date?) -> Text { Text(recencyLabel(date)) }

  /// `recency`'s wording, as a run something else can join.
  static func recencyLabel(_ date: Date?) -> String {
    guard let date else { return String(localized: "no activity captured") }
    return relative(date)
  }

  /// "3 weeks ago · 21 Jul, 18:04" — for the detail header, which has the width for both. The
  /// absolute stamp is the one the Recent Activity timeline below repeats.
  static func recencyDetailed(_ date: Date?) -> String {
    guard let date else { return String(localized: "no activity captured") }
    return relative(date)
      + separator
      + date.formatted(.dateTime.day().month().hour().minute())
  }

  /// "14 open" / "14 offen". Interpolates an `Int`, so its catalog key MUST be `"%lld open"` —
  /// `"%@ open"` will not match and will silently fall back to English.
  static func openCount(_ count: Int) -> String { String(localized: "\(count) open") }

  /// Verbatim punctuation between facts — never localized, so it carries no key.
  static let separator = " · "
}

/// The detail header's state line, assembled on a **mark-the-exception rule**: a fact renders only
/// when it is not the unmarked default. A project says no kind; an active node says no state; a node
/// without a branch renders no branch slot. This is why it is a line and not a fixed grid — a grid
/// would leave an empty cell on most nodes.
struct NodeMetaLine: View {
  let node: Node
  let facts: NodeRowFacts?

  var body: some View {
    joined(tokens).metaText()
  }

  /// `AttributedString` rather than `String` because one token — the branch key — is styled on its
  /// own. The monospacing rides on `inlinePresentationIntent`, not on the `font` attribute: this
  /// SDK's SwiftUI attribute scope has no `fontDesign` (probed — it fails to resolve), and setting
  /// `font` would name a size and override the 12pt `.metaText()` applies below.
  private var tokens: [AttributedString] {
    var result: [AttributedString] = []
    if node.kind != .project {
      result.append(AttributedString(String(localized: AppearanceStyle.kindLabel(node.kind))))
    }
    if node.state != .active {
      result.append(AttributedString(String(localized: AppearanceStyle.stateLabel(node.state))))
    }
    result.append(AttributedString(NodeMeta.recencyDetailed(facts?.lastActivityAt)))
    result.append(AttributedString(NodeMeta.openCount(facts?.openLooseEnds ?? 0)))
    // Content, never localized — a branch name is verbatim.
    if let branchKey = node.branchKey, !branchKey.isEmpty {
      var branch = AttributedString(branchKey)
      branch.inlinePresentationIntent = .code
      result.append(branch)
    }
    return result
  }

  private func joined(_ parts: [AttributedString]) -> Text {
    guard let first = parts.first else { return Text(verbatim: "") }
    let separator = AttributedString(NodeMeta.separator)
    return Text(parts.dropFirst().reduce(first) { $0 + separator + $1 })
  }
}

/// A list row's second line: recency and volume, the two facts that fit a narrow column. It replaces
/// the node's kind label, which was identical on every row and so discriminated nothing.
struct NodeRowMeta: View {
  let facts: NodeRowFacts?

  var body: some View {
    Text(NodeMeta.recencyLabel(facts?.lastActivityAt)
      + NodeMeta.separator
      + NodeMeta.openCount(facts?.openLooseEnds ?? 0))
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}
