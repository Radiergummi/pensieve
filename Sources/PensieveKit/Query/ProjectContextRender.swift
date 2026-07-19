import Foundation

/// Pure renderers for a ProjectContextBundle. Markdown feeds MCP resources (Claude Code renders
/// it); compact plain text feeds the `prime` hook's additionalContext. Both omit prose when nil.
public enum SessionContextRender {
  public static func markdown(_ b: ProjectContextBundle) -> String {
    var out = "# \(b.name)\n"
    if !b.description.isEmpty { out += "\n\(b.description)\n" }
    out += "\n*\(b.kind.rawValue) · \(b.daysDormant)d dormant · \(b.openLooseEndCount) open loose end(s)*\n"
    if let prose = b.prose {
      out += "\n## Last Work Done\n\n\(prose)\n"
    }
    if !b.looseEnds.isEmpty {
      out += "\n## Open Loose Ends\n\n"
      for le in b.looseEnds {
        out += "- \(le.text)\n  > \(le.quote)\n"
      }
    }
    if !b.recentEvents.isEmpty {
      out += "\n## Recent Activity\n\n"
      for e in b.recentEvents { out += "- \(e.summary)\n" }
    }
    return out
  }

  /// Plain-text bundle for the always-on `prime` SessionStart hook. Loose ends are capped
  /// (with a "+N more" tail) so a project with a long backlog can't flood the session context.
  public static func compact(_ b: ProjectContextBundle, maxLooseEnds: Int = 8) -> String {
    var lines: [String] = []
    lines.append("Pensieve — \(b.name) (\(b.daysDormant)d dormant, \(b.openLooseEndCount) open loose end(s))")
    if let prose = b.prose { lines.append(prose) }
    if !b.looseEnds.isEmpty {
      lines.append("Open loose ends:")
      for le in b.looseEnds.prefix(maxLooseEnds) { lines.append("• \(le.text) — \"\(le.quote)\"") }
      let remaining = b.looseEnds.count - maxLooseEnds
      if remaining > 0 { lines.append("… and \(remaining) more") }
    }
    return lines.joined(separator: "\n")
  }

  /// Markdown for the `whats_next` MCP resource: a ranked cross-project queue, each row citing
  /// its oldest open loose end. Kept here (tested Kit) rather than inline in the CLI server.
  public static func whatsNext(_ items: [WhatsNextItem]) -> String {
    var out = "# What's Next\n\n"
    for i in items {
      out += "- **\(i.name)** — \(i.openLooseEnds) open, \(i.daysDormant)d dormant"
      if let q = i.topLooseEnd { out += "\n  > \(q)" }
      out += "\n"
    }
    return out
  }
}
