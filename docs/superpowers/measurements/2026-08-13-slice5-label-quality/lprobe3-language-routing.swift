// THROWAWAY SPIKE 3 — is NLLanguageRecognizer reliable enough to route on, and is a
// deterministic word-boundary shortening a usable German fallback?
import Foundation
import NaturalLanguage

func detect(_ text: String) -> (String, Double) {
  let recognizer = NLLanguageRecognizer()
  recognizer.processString(text)
  guard let language = recognizer.dominantLanguage else { return ("nil", 0) }
  let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
  return (language.rawValue, confidence)
}

// Deterministic shortening: whole words, <= cap, no model involved.
func shorten(_ text: String, cap: Int = 60) -> String? {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  if trimmed.count <= cap { return trimmed }
  var out = ""
  for word in trimmed.split(separator: " ") {
    if out.isEmpty { out = String(word) }
    else if out.count + 1 + word.count <= cap { out += " " + word }
    else { break }
  }
  return out.isEmpty ? String(trimmed.prefix(cap)) : out
}

let cases = [
  "look into why the background sync agent stopped spawning",
  "Steuerunterlagen für 2025 zusammenstellen",
  "die Bahn-Reklamation für die verspätete Fahrt einreichen",
  "Geschenk für Mamas Geburtstag besorgen",
  "den Mietvertrag kündigen und die Kaution zurückfordern",
  "taxes",                                   // 1 word EN — detection's weak spot
  "Steuer",                                  // 1 word DE — ditto
  "fix the German truncation in the menu bar footer",
  "Bahn-Reklamation einreichen",             // short DE
  "migrate the loose end resolution verbs into the CLI",
  "I want to eventually get around to thinking about whether the whole typed tree thing should maybe be reconsidered because projects and strands are not the same kind of thing",
]

for sentence in cases {
  let (language, confidence) = detect(sentence)
  let short = shorten(sentence) ?? "-"
  print("\(language) \(String(format: "%.2f", confidence))  \(sentence.count)c")
  print("   in:    \(sentence.prefix(80))")
  print("   short: \(short)  (\(short.count)c)")
}
