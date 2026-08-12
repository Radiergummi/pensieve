import Foundation

/// Renders a node's recall as an English Markdown snapshot for sharing. Pure and deterministic:
/// no DB, no LLM, no localization. `narration` nil/empty ⇒ the Last Work Done section is omitted.
/// Emits loose-end SUMMARY text only — a loose end's verbatim `quote` is never included.
public enum RecallMarkdown {
  /// `translatedLooseEndText` mirrors `NodeFindDocument.make`'s parameter of the same name: the
  /// on-demand translation of a loose end's summary, when one is stored, else the English original.
  /// Defaulted so existing call sites compile untouched.
  public static func render(node: Node, narration: String?, looseEnds: [LooseEndView],
                            events: [Event], now: Date,
                            translatedLooseEndText: [UUID: String] = [:]) -> String {
    var out: [String] = []
    out.append("# \(node.name)")
    out.append("")
    out.append("*\(capitalizedFirst(node.kind.rawValue)) · \(capitalizedFirst(node.state.rawValue))*")

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
      for looseEnd in looseEnds {
        let text = translatedLooseEndText[looseEnd.looseEnd.id] ?? looseEnd.looseEnd.text
        out.append("- \(text)")
      }
    }

    out.append("")
    out.append("## Recent Activity")
    out.append("")
    if events.isEmpty {
      out.append("_No captured activity._")
    } else {
      for event in events { out.append("- \(day(event.occurredAt)) — \(event.summary)") }
    }

    out.append("")
    out.append("---")
    out.append("_Shared from Pensieve · \(day(now))_")

    return out.joined(separator: "\n") + "\n"
  }

  private static func capitalizedFirst(_ text: String) -> String {
    text.isEmpty ? text : text.prefix(1).uppercased() + text.dropFirst()
  }

  /// yyyy-MM-dd in the current timezone. A local (non-static) formatter — Swift-6-safe.
  private static func day(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
}
