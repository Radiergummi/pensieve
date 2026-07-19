import Foundation
import Testing
@testable import PensieveKit

@Test func deepLinkRoundTripsBriefing() {
  let link = DeepLink.briefing
  #expect(DeepLink(url: link.url) == link)
  #expect(link.url.absoluteString == "pensieve://briefing")
}

@Test func deepLinkRoundTripsNode() {
  let link = DeepLink.node(UUID())
  #expect(DeepLink(url: link.url) == link)
}

@Test func deepLinkRoundTripsEverySmartList() {
  for kind in [DeepLink.SmartList.whatsNext, .dormant, .recentlyActive] {
    let link = DeepLink.smartList(kind)
    #expect(DeepLink(url: link.url) == link)
  }
}

@Test func deepLinkParsesKnownForms() {
  #expect(DeepLink(url: URL(string: "pensieve://briefing")!) == .briefing)
  #expect(DeepLink(url: URL(string: "pensieve://smartlist/dormant")!) == .smartList(.dormant))
  let id = UUID()
  #expect(DeepLink(url: URL(string: "pensieve://node/\(id.uuidString)")!) == .node(id))
}

@Test func deepLinkRejectsMalformed() {
  #expect(DeepLink(url: URL(string: "http://briefing")!) == nil)            // wrong scheme
  #expect(DeepLink(url: URL(string: "pensieve://unknown")!) == nil)         // unknown host
  #expect(DeepLink(url: URL(string: "pensieve://node")!) == nil)            // missing uuid
  #expect(DeepLink(url: URL(string: "pensieve://node/not-a-uuid")!) == nil) // bad uuid
  #expect(DeepLink(url: URL(string: "pensieve://smartlist/nope")!) == nil)  // unknown token
  #expect(DeepLink(url: URL(string: "pensieve://briefing/extra")!) == nil)  // trailing path
}

@Test func deepLinkSmartListTokensAreStable() {
  // MUST match the app's SmartListKind raw values.
  #expect(DeepLink.SmartList.whatsNext.rawValue == "whatsNext")
  #expect(DeepLink.SmartList.dormant.rawValue == "dormant")
  #expect(DeepLink.SmartList.recentlyActive.rawValue == "recentlyActive")
}

@Test func deepLinkRoundTripsLooseEnd() {
  let link = DeepLink.looseEnd(UUID())
  #expect(DeepLink(url: link.url) == link)
}

@Test func deepLinkParsesLooseEndForm() {
  let id = UUID()
  #expect(DeepLink(url: URL(string: "pensieve://looseend/\(id.uuidString)")!) == .looseEnd(id))
}

@Test func deepLinkRejectsMalformedLooseEnd() {
  #expect(DeepLink(url: URL(string: "pensieve://looseend")!) == nil)             // missing uuid
  #expect(DeepLink(url: URL(string: "pensieve://looseend/not-a-uuid")!) == nil)  // bad uuid
  let id = UUID()
  #expect(DeepLink(url: URL(string: "pensieve://looseend/\(id.uuidString)/extra")!) == nil) // trailing
}
