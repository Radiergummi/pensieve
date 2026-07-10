import Foundation

/// Pure renderers for a ProjectContextBundle. Markdown feeds MCP resources (Claude Code renders
/// it); compact plain text feeds the `prime` hook's additionalContext. Both omit prose when nil.
public enum SessionContextRender {
  public static func markdown(_ b: ProjectContextBundle) -> String {
    var out = "# \(b.name)\n"
    if !b.description.isEmpty { out += "\n\(b.description)\n" }
    out += "\n*\(b.kind) · \(b.daysDormant)d dormant · \(b.openLooseEndCount) open loose end(s)*\n"
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

  public static func compact(_ b: ProjectContextBundle) -> String {
    var lines: [String] = []
    lines.append("Pensieve — \(b.name) (\(b.daysDormant)d dormant, \(b.openLooseEndCount) open loose end(s))")
    if let prose = b.prose { lines.append(prose) }
    if !b.looseEnds.isEmpty {
      lines.append("Open loose ends:")
      for le in b.looseEnds { lines.append("• \(le.text) — \"\(le.quote)\"") }
    }
    return lines.joined(separator: "\n")
  }
}
