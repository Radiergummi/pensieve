import Foundation

/// A JSON tree that survives a round trip through this tool byte-for-byte.
///
/// `JSONSerialization` hands back `Any`, in which a Bool and a number are the same bridged type;
/// re-encoding that naively rewrites `"shouldTranslate" : false` as `0`. And `JSONEncoder` cannot
/// produce Xcode's layout at all — it writes `"key":value` or, with `.prettyPrinted`, `"key" : value`
/// with no control over ordering. So the tree is modelled explicitly and rendered by hand.
///
/// Being generic is the point: `comment`, `extractionState`, plural `variations` and anything a
/// future Xcode adds ride through untouched, because nothing here knows their shape.
indirect enum JSONValue {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  /// Kept as the source text. The catalog holds no numbers today, and reformatting one through a
  /// `Double` is a silent way to turn `1.0` into `1` in a file this tool is supposed to leave alone.
  case number(String)
  case bool(Bool)
  case null

  static func from(_ value: Any) -> JSONValue {
    if let text = value as? String { return .string(text) }
    if let dictionary = value as? [String: Any] { return .object(dictionary.mapValues(JSONValue.from)) }
    if let list = value as? [Any] { return .array(list.map(JSONValue.from)) }
    if value is NSNull { return .null }
    if let number = value as? NSNumber {
      // The one distinction the bridge loses: `false` and `0` are both NSNumber, and only the
      // CoreFoundation type id tells them apart.
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
      return .number(number.stringValue)
    }
    return .null
  }

  var asObject: [String: JSONValue]? {
    if case .object(let object) = self { return object }
    return nil
  }

  var asString: String? {
    if case .string(let text) = self { return text }
    return nil
  }

  var asBool: Bool? {
    if case .bool(let flag) = self { return flag }
    return nil
  }
}

// MARK: - Canonical rendering

/// CLDR's category order, which is what Xcode writes and what reads correctly to a translator:
/// `one` before `other`, not the alphabetical `few, many, one, other, two, zero`.
private let pluralCategoryOrder = ["zero", "one", "two", "few", "many", "other"]

/// Sorted by Unicode scalar rather than by `String`'s collation, so the order depends on the bytes in
/// the file and not on locale or ICU version. Keys here are UI copy — they contain umlauts, ellipses
/// and middots, exactly the characters the two orderings disagree about.
private func orderedKeys(_ object: [String: JSONValue], parentKey: String?) -> [String] {
  guard parentKey == "plural" else {
    return object.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
  }
  return object.keys.sorted { lhs, rhs in
    let lhsRank = pluralCategoryOrder.firstIndex(of: lhs) ?? pluralCategoryOrder.count
    let rhsRank = pluralCategoryOrder.firstIndex(of: rhs) ?? pluralCategoryOrder.count
    return (lhsRank, lhs) < (rhsRank, rhs)
  }
}

/// JSON string escaping that leaves non-ASCII alone. The catalog is UTF-8 and full of German; escaping
/// `ü` to `ü` would be valid JSON and an unreadable diff.
private func escaped(_ text: String) -> String {
  var rendered = ""
  for scalar in text.unicodeScalars {
    switch scalar {
    case "\"": rendered += "\\\""
    case "\\": rendered += "\\\\"
    case "\n": rendered += "\\n"
    case "\r": rendered += "\\r"
    case "\t": rendered += "\\t"
    default:
      if scalar.value < 0x20 {
        rendered += String(format: "\\u%04x", scalar.value)
      } else {
        rendered.unicodeScalars.append(scalar)
      }
    }
  }
  return rendered
}

extension JSONValue {
  /// Xcode's layout: two spaces per level, a space on each side of the colon, keys sorted.
  func rendered(indent: Int = 0, parentKey: String? = nil) -> String {
    let pad = String(repeating: " ", count: indent * 2)
    let innerPad = String(repeating: " ", count: (indent + 1) * 2)
    switch self {
    case .string(let text):
      return "\"\(escaped(text))\""
    case .number(let text):
      return text
    case .bool(let flag):
      return flag ? "true" : "false"
    case .null:
      return "null"
    case .array(let items):
      guard !items.isEmpty else { return "[]" }
      let body = items.map { innerPad + $0.rendered(indent: indent + 1) }.joined(separator: ",\n")
      return "[\n\(body)\n\(pad)]"
    case .object(let object):
      guard !object.isEmpty else { return "{}" }
      let body = orderedKeys(object, parentKey: parentKey).compactMap { key -> String? in
        guard let value = object[key] else { return nil }
        return "\(innerPad)\"\(escaped(key))\" : \(value.rendered(indent: indent + 1, parentKey: key))"
      }.joined(separator: ",\n")
      return "{\n\(body)\n\(pad)}"
    }
  }
}
