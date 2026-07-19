import Foundation
import Testing
@testable import PensieveKit

@Test func appearanceIconParsesBothSchemes() {
  #expect(AppearanceIcon.parse("sf:flag") == .sfSymbol("flag"))
  #expect(AppearanceIcon.parse("emoji:🚀") == .emoji("🚀"))
  #expect(AppearanceIcon.parse("") == nil)          // empty → caller falls back
  #expect(AppearanceIcon.parse("garbage") == nil)   // malformed → nil
  #expect(AppearanceIcon.parse("sf:") == nil)       // empty payload → nil
  #expect(AppearanceIcon.sfSymbol("flag").storedString == "sf:flag")
  #expect(AppearanceIcon.emoji("🚀").storedString == "emoji:🚀")
}

@Test func everyNodeKindHasADefaultStyle() {
  for kind in NodeKind.all {
    let s = NodeKindStyle.style(for: kind)
    #expect(!s.icon.isEmpty)
    #expect(!s.colorTag.isEmpty)
    #expect(AppearanceIcon.parse(s.icon) != nil)   // the default is a parseable icon string
  }
  // `NodeKind` is now a closed enum — an unknown kind is impossible by construction, so the
  // former string-fallback assertion is gone (the compiler proves exhaustiveness).
}

@Test func everyCaptureKindHasASourceStyle() {
  for kind in [CaptureKind.gitCommit, CaptureKind.gitCheckout, CaptureKind.ccSession, CaptureKind.ccSessionStart] {
    let s = EventSourceStyle.style(for: kind)
    #expect(!s.icon.isEmpty)
    #expect(!s.colorTag.isEmpty)
  }
  #expect(!EventSourceStyle.style(for: "unknown.kind").icon.isEmpty)   // fallback
}

@Test func nodeAppearanceOwnValueWinsElseKindDefault() {
  // Empty appearance → falls back to the kind default.
  let plain = Node(name: "P", kind: NodeKind.strand)
  #expect(plain.appearance.colorTag == NodeKindStyle.style(for: NodeKind.strand).colorTag)
  #expect(plain.appearance.icon == AppearanceIcon.parse(NodeKindStyle.style(for: NodeKind.strand).icon))

  // Own values win.
  let custom = Node(name: "C", kind: NodeKind.strand, icon: "emoji:🎯", colorTag: "pink")
  #expect(custom.appearance.icon == .emoji("🎯"))
  #expect(custom.appearance.colorTag == "pink")

  // Malformed own icon → kind default icon; own color still applies.
  let partial = Node(name: "M", kind: NodeKind.task, icon: "garbage", colorTag: "red")
  #expect(partial.appearance.icon == AppearanceIcon.parse(NodeKindStyle.style(for: NodeKind.task).icon))
  #expect(partial.appearance.colorTag == "red")
}
