import Foundation

/// Extracts the first COMPLETE top-level JSON array from arbitrary model output — from the
/// first `[` to its matching `]`, tracking string literals and nesting so that trailing model
/// prose or a `]` inside a quoted value can neither truncate nor over-extend the slice.
/// Returns nil when there is no `[` or the array is unterminated.
///
/// This replaces a naive first-`[`…last-`]` slice, which dropped a whole batch's results
/// whenever the model appended prose containing a `]`. Only the text-based provider default
/// (`claude -p`) and tests use it; the on-device provider returns structure directly.
func firstJSONArray(in raw: String) -> String? {
  guard let start = raw.firstIndex(of: "[") else { return nil }
  var depth = 0, inString = false, escaped = false
  var index = start
  while index < raw.endIndex {
    let character = raw[index]
    if inString {
      consumeStringCharacter(character, escaped: &escaped, inString: &inString)
    } else if consumeStructuralCharacter(character, depth: &depth, inString: &inString) {
      return String(raw[start...index])
    }
    index = raw.index(after: index)
  }
  return nil
}

/// Tracks escape/quote state for a character known to be inside a JSON string literal.
private func consumeStringCharacter(_ character: Character, escaped: inout Bool, inString: inout Bool) {
  if escaped {
    escaped = false
  } else if character == "\\" {
    escaped = true
  } else if character == "\"" {
    inString = false
  }
}

/// Tracks bracket depth for a character known to be outside a JSON string literal.
/// Returns true when this character closes the top-level array (`depth` reaches 0 on `]`).
private func consumeStructuralCharacter(_ character: Character, depth: inout Int, inString: inout Bool) -> Bool {
  switch character {
  case "\"": inString = true
  case "[": depth += 1
  case "]":
    depth -= 1
    return depth == 0
  default: break
  }
  return false
}
