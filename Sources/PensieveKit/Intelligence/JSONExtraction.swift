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
  var i = start
  while i < raw.endIndex {
    let c = raw[i]
    if inString {
      if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
    } else {
      switch c {
      case "\"": inString = true
      case "[": depth += 1
      case "]":
        depth -= 1
        if depth == 0 { return String(raw[start...i]) }
      default: break
      }
    }
    i = raw.index(after: i)
  }
  return nil
}
