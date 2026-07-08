import Foundation

/// Renders a node's recall as an English Markdown snapshot for sharing. Pure and deterministic:
/// no DB, no LLM, no localization. `narration` nil/empty ⇒ the Last Work Done section is omitted.
/// Emits loose-end SUMMARY text only — a loose end's verbatim `quote` is never included.
public enum RecallMarkdown {
  public static func render(node: Node, narration: String?, looseEnds: [LooseEndView],
                            events: [Event], now: Date) -> String {
    var out: [String] = []
    out.append("# \(node.name)")
    out.append("")
    out.append("*\(capitalizedFirst(node.kind)) · \(capitalizedFirst(node.state))*")

    if !node.description.isEmpty {
      out.append("")
      out.append(node.description)
    }

    if let narration, !narration.isEmpty {
      out.append("")
      out.append("## Last Work Done")
      out.append("")
      out.append(narration)
    }

    out.append("")
    out.append("## Loose Ends")
    out.append("")
    if looseEnds.isEmpty {
      out.append("_None open._")
    } else {
      for le in looseEnds { out.append("- \(le.looseEnd.text)") }
    }

    out.append("")
    out.append("## Recent Activity")
    out.append("")
    if events.isEmpty {
      out.append("_No captured activity._")
    } else {
      for e in events { out.append("- \(day(e.occurredAt)) — \(e.summary)") }
    }

    out.append("")
    out.append("---")
    out.append("_Shared from Pensieve · \(day(now))_")

    return out.joined(separator: "\n") + "\n"
  }

  private static func capitalizedFirst(_ s: String) -> String {
    s.isEmpty ? s : s.prefix(1).uppercased() + s.dropFirst()
  }

  /// yyyy-MM-dd in the current timezone. A local (non-static) formatter — Swift-6-safe.
  private static func day(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
  }
}
