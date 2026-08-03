import Foundation

/// Pure renderers for a ProjectContextBundle. Markdown feeds MCP resources (Claude Code renders
/// it); compact plain text feeds the `prime` hook's additionalContext. Both omit prose when nil.
public enum SessionContextRender {
  public static func markdown(_ bundle: ProjectContextBundle) -> String {
    var out = "# \(bundle.name)\n"
    if !bundle.description.isEmpty { out += "\n\(bundle.description)\n" }
    out += "\n*\(bundle.kind.rawValue) · \(bundle.daysDormant)d dormant · \(bundle.openLooseEndCount) open loose end(s)*\n"
    if let prose = bundle.prose {
      out += "\n## Last Work Done\n\n\(prose)\n"
    }
    if !bundle.looseEnds.isEmpty {
      out += "\n## Open Loose Ends\n\n"
      for looseEnd in bundle.looseEnds {
        out += "- \(looseEnd.text)\n  > \(looseEnd.quote)\n"
      }
    }
    if !bundle.recentEvents.isEmpty {
      out += "\n## Recent Activity\n\n"
      for event in bundle.recentEvents { out += "- \(event.summary)\n" }
    }
    return out
  }

  /// Plain-text bundle for the always-on `prime` SessionStart hook. Loose ends are capped
  /// (with a "+N more" tail) so a project with a long backlog can't flood the session context.
  public static func compact(_ bundle: ProjectContextBundle, maxLooseEnds: Int = 8) -> String {
    var lines: [String] = []
    lines.append("Pensieve — \(bundle.name) (\(bundle.daysDormant)d dormant, \(bundle.openLooseEndCount) open loose end(s))")
    if let prose = bundle.prose { lines.append(prose) }
    if !bundle.looseEnds.isEmpty {
      lines.append("Open loose ends:")
      for looseEnd in bundle.looseEnds.prefix(maxLooseEnds) { lines.append("• \(looseEnd.text) — \"\(looseEnd.quote)\"") }
      let remaining = bundle.looseEnds.count - maxLooseEnds
      if remaining > 0 { lines.append("… and \(remaining) more") }
    }
    return lines.joined(separator: "\n")
  }

  /// Markdown for the `whats_next` MCP resource: a ranked cross-project queue, each row citing
  /// its oldest open loose end. Kept here (tested Kit) rather than inline in the CLI server.
  public static func whatsNext(_ items: [WhatsNextItem]) -> String {
    var out = "# What's Next\n\n"
    for item in items {
      out += "- **\(item.name)** — \(item.openLooseEnds) open, \(item.daysDormant)d dormant"
      if let topLooseEnd = item.topLooseEnd { out += "\n  > \(topLooseEnd)" }
      out += "\n"
    }
    return out
  }
}
