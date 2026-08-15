import ApplicationServices
import Cocoa

/// A thin value wrapper over `AXUIElement`. Every accessor returns nil/empty rather than throwing:
/// a probe that dies on one unreadable attribute is useless against a live, changing UI.
struct AccessibilityElement {
  let element: AXUIElement

  init(element: AXUIElement) { self.element = element }

  init(application processIdentifier: pid_t) {
    self.element = AXUIElementCreateApplication(processIdentifier)
  }

  private func copyAttribute(_ attribute: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  func text(_ attribute: String) -> String? {
    guard let value = copyAttribute(attribute) as? String, !value.isEmpty else { return nil }
    return value
  }

  var role: String { text(kAXRoleAttribute) ?? "AXUnknown" }
  var identifier: String? { text(kAXIdentifierAttribute) }
  var isSelected: Bool { copyAttribute(kAXSelectedAttribute) as? Bool ?? false }

  var children: [AccessibilityElement] {
    (copyAttribute(kAXChildrenAttribute) as? [AXUIElement] ?? []).map(AccessibilityElement.init(element:))
  }

  var parent: AccessibilityElement? {
    guard let raw = copyAttribute(kAXParentAttribute),
          CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    // Guarded by the CFTypeID check above, which is the check the compiler itself suggests: a
    // conditional downcast to a CoreFoundation type is a hard error here ("will always succeed"),
    // so `as?` is not available and the type test has to be explicit. The cast cannot fail.
    // swiftlint:disable:next force_cast
    return AccessibilityElement(element: raw as! AXUIElement)
  }

  var windows: [AccessibilityElement] {
    (copyAttribute(kAXWindowsAttribute) as? [AXUIElement] ?? []).map(AccessibilityElement.init(element:))
  }

  var frame: CGRect? {
    guard let rawPosition = copyAttribute(kAXPositionAttribute),
          let rawSize = copyAttribute(kAXSizeAttribute),
          CFGetTypeID(rawPosition) == AXValueGetTypeID(),
          CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    // Same CFTypeID-guarded casts as `parent` above — see the note there.
    // swiftlint:disable:next force_cast
    AXValueGetValue(rawPosition as! AXValue, .cgPoint, &origin)
    // swiftlint:disable:next force_cast
    AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
  }

  /// The best single label for this element, used for `find`/`select`/`click` matching.
  var primaryText: String? {
    text(kAXValueAttribute) ?? text(kAXTitleAttribute) ?? text(kAXDescriptionAttribute)
  }

  /// One line of `dump` output: role, then every non-empty text attribute, then flags.
  var descriptionLine: String {
    var parts = [role]
    for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
      if let value = text(attribute) {
        parts.append("\(attribute.dropFirst(2)): \u{201C}\(value)\u{201D}")
      }
    }
    if let identifier { parts.append("id: \(identifier)") }
    if isSelected { parts.append("SELECTED") }
    return parts.joined(separator: "  ")
  }
}

/// Depth-first search for the first element whose primary text equals `needle`.
/// Exact match, not substring: a substring match on a tree this size returns the wrong row often
/// enough to be worse than no match at all.
func firstDescendant(of root: AccessibilityElement,
                     matchingText needle: String,
                     depth: Int = 0) -> AccessibilityElement? {
  if depth > 40 { return nil }
  if root.primaryText == needle { return root }
  for child in root.children {
    if let hit = firstDescendant(of: child, matchingText: needle, depth: depth + 1) { return hit }
  }
  return nil
}

/// Walks up to the nearest ancestor with the given role. SwiftUI list selection is driven on the
/// `AXRow`, which is several levels above the `AXStaticText` a human would name.
func nearestAncestor(of element: AccessibilityElement, role wanted: String) -> AccessibilityElement? {
  var current: AccessibilityElement? = element
  for _ in 0..<10 {
    guard let candidate = current else { return nil }
    if candidate.role == wanted { return candidate }
    current = candidate.parent
  }
  return nil
}
