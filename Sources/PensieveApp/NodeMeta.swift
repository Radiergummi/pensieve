// Sources/PensieveApp/NodeMeta.swift
import SwiftUI
import PensieveKit

/// How a node's grounded facts render as text. One place, so the detail header, the middle-column row
/// and the Briefing agree on wording — and on what a node with no captured activity looks like.
///
/// Relative dates carry **no String Catalog key at all**: `Text(_, format: .relative(...))` is
/// localized by Foundation. That is the whole point of the Kit carrying a `Date` rather than a day
/// count — see the spec's `%@` vs `%lld` table for what the hand-keyed integer strings did instead.
enum NodeMeta {
  /// "3 weeks ago" / "vor 3 Wochen". A node with no captured events says so, rather than claiming a
  /// zero it does not have.
  static func recency(_ date: Date?) -> Text {
    guard let date else { return Text("no activity captured") }
    return Text(date, format: .relative(presentation: .named))
  }

  /// "3 weeks ago · 21 Jul, 18:04" — for the detail header, which has the width for both. The
  /// absolute stamp is the one the Recent Activity timeline below repeats.
  static func recencyDetailed(_ date: Date?) -> Text {
    guard let date else { return Text("no activity captured") }
    return Text(date, format: .relative(presentation: .named))
      + Text(verbatim: " · ")
      + Text(date, format: .dateTime.day().month().hour().minute())
  }

  /// "14 open" / "14 offen". Interpolates an `Int`, so its catalog key MUST be `"%lld open"` —
  /// `"%@ open"` will not match and will silently fall back to English.
  static func openCount(_ count: Int) -> Text { Text("\(count) open") }
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

  private var tokens: [Text] {
    var result: [Text] = []
    if node.kind != .project { result.append(Text(AppearanceStyle.kindLabel(node.kind))) }
    if node.state != .active { result.append(Text(AppearanceStyle.stateLabel(node.state))) }
    result.append(NodeMeta.recencyDetailed(facts?.lastActivityAt))
    result.append(NodeMeta.openCount(facts?.openLooseEnds ?? 0))
    // Content, never localized — a branch name is verbatim.
    if let branchKey = node.branchKey, !branchKey.isEmpty {
      result.append(Text(branchKey).monospaced())
    }
    return result
  }

  private func joined(_ parts: [Text]) -> Text {
    guard let first = parts.first else { return Text(verbatim: "") }
    return parts.dropFirst().reduce(first) { $0 + Text(verbatim: " · ") + $1 }
  }
}

/// A list row's second line: recency and volume, the two facts that fit a narrow column. It replaces
/// the node's kind label, which was identical on every row and so discriminated nothing.
struct NodeRowMeta: View {
  let facts: NodeRowFacts?

  var body: some View {
    (NodeMeta.recency(facts?.lastActivityAt)
      + Text(verbatim: " · ")
      + NodeMeta.openCount(facts?.openLooseEnds ?? 0))
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}
