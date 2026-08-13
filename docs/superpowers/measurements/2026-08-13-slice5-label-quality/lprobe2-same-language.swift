// THROWAWAY SPIKE 2 — does a same-language instruction fix the German→English translation?
import Foundation
import FoundationModels

func promptA(_ typed: String) -> String {   // the shape probe 1 used
  """
  Below is a developer's own description of a piece of work they are about to start. In 3-6 words, \
  give it a human-readable name — a plain label for a sidebar, not numbered or bulleted, no \
  trailing period. Reply with the label only, nothing else. Do not invent facts beyond the \
  description.

  \(typed)
  """
}

func promptB(_ typed: String) -> String {   // + same-language instruction
  """
  Below is a developer's own description of a piece of work they are about to start. In 3-6 words, \
  give it a human-readable name — a plain label for a sidebar, not numbered or bulleted, no \
  trailing period. Write the label in the SAME LANGUAGE as the description; do not translate it. \
  Reuse the description's own words where you can. Reply with the label only, nothing else. Do not \
  invent facts beyond the description.

  \(typed)
  """
}

let cases = [
  "Steuerunterlagen für 2025 zusammenstellen",
  "die Bahn-Reklamation für die verspätete Fahrt einreichen",
  "Geschenk für Mamas Geburtstag besorgen",
  "den Mietvertrag kündigen und die Kaution zurückfordern",
  // the two English cases where probe 1 dropped the distinguishing term
  "migrate the loose end resolution verbs into the CLI",
  "spike whether writing tools can attach to a markdown view",
]

for (index, sentence) in cases.enumerated() {
  print("[\(index + 1)] in: \(sentence)")
  for (tag, prompt) in [("A/base", promptA(sentence)), ("B/same-lang", promptB(sentence))] {
    let session = LanguageModelSession()   // fresh session: no cross-variant contamination
    do {
      let raw = try await session.respond(to: prompt).content
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ⏎ ")
      print("      \(tag): \(raw)")
    } catch { print("      \(tag): ERROR \(error)") }
  }
}
