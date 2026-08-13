// THROWAWAY SPIKE — slice 5 label quality.
// Standalone by design (the retrieval probes set this precedent): imports no PensieveKit type,
// carries its own copy of the gate so what it measures is exactly what would ship.
import Foundation
import FoundationModels

// ---- copied verbatim from TextQuality.isTerseLabel + Ingester.sanitizeStrandName ----
let labelLengthCap = 60

func isTerseLabel(_ text: String) -> Bool {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty, trimmed.count <= labelLengthCap else { return false }
  return trimmed.range(of: #"[.!?]\s+\p{Lu}"#, options: .regularExpression) == nil
}

func sanitizeLabel(_ raw: String) -> String? {
  var sanitized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  if let marker = sanitized.range(of: #"^(\d+[.)]|[-*•])\s+"#, options: .regularExpression) {
    sanitized.removeSubrange(marker)
  }
  sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
  sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
  sanitized = sanitized.trimmingCharacters(in: .whitespaces)
  guard isTerseLabel(sanitized) else { return nil }
  return sanitized
}

// ---- the candidate prompt, mirroring Ingester.nameStrand's proven shape ----
func labelPrompt(_ typed: String) -> String {
  """
  Below is a developer's own description of a piece of work they are about to start. In 3-6 words, \
  give it a human-readable name — a plain label for a sidebar, not numbered or bulleted, no \
  trailing period. Reply with the label only, nothing else. Do not invent facts beyond the \
  description.

  \(typed)
  """
}

// 20 realistic quick-adds spanning this user's actual domains, incl. 3 German and
// 2 deliberately awkward inputs (very short, and very long/rambling).
let sentences = [
  "look into why the background sync agent stopped spawning",
  "write the paraphrase eval gold set for retrieval",
  "add a settings tab for source management",
  "transcript passage chunking so search can find passages not just documents",
  "figure out the widget story once the paid signing gate clears",
  "rebuild the menu bar popover so each row has its own action",
  "fix the German truncation in the menu bar footer",
  "clean up the colibri postgres backups",
  "matchory supplier search ranking is off for german queries",
  "draft the onboarding email sequence for matchory",
  "migrate the loose end resolution verbs into the CLI",
  "spike whether writing tools can attach to a markdown view",
  "syntax highlighting for transcript code fences",
  "prev next navigation between nodes so I stop bouncing back to the list",
  "merge inbox for duplicate nodes, the sidebar shows Agent twice",
  "narration keeps emitting a facts dump instead of a recap",
  "Steuerunterlagen für 2025 zusammenstellen",
  "die Bahn-Reklamation für die verspätete Fahrt einreichen",
  "Geschenk für Mamas Geburtstag besorgen",
  "taxes",
  "I want to eventually get around to thinking about whether the whole typed tree thing should maybe be reconsidered because it feels like projects and strands are not really the same kind of thing at all and maybe there should be a third level",
]

let session = LanguageModelSession()
var accepted = 0, rejected = 0

print("n=\(sentences.count)  cap=\(labelLengthCap)\n")

for (index, sentence) in sentences.enumerated() {
  do {
    let raw = try await session.respond(to: labelPrompt(sentence)).content
    let oneLine = raw.replacingOccurrences(of: "\n", with: " ⏎ ")
    if let label = sanitizeLabel(raw) {
      accepted += 1
      print("[\(index + 1)] ✅ \(label)   (\(label.count)c)")
    } else {
      rejected += 1
      print("[\(index + 1)] ❌ REJECTED  raw=\"\(oneLine.prefix(120))\"")
    }
    print("      in: \(sentence.prefix(90))")
  } catch {
    rejected += 1
    print("[\(index + 1)] ⚠️  ERROR \(error)")
  }
}

print("\naccepted=\(accepted)  rejected=\(rejected)  of \(sentences.count)")
