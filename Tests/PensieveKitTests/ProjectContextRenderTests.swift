import Foundation
import Testing
@testable import PensieveKit

private func sampleBundle(prose: String?) -> ProjectContextBundle {
  ProjectContextBundle(
    nodeID: UUID(), name: "Pensieve", kind: NodeKind.project,
    description: "context reconstruction tool", context: NodeContext.work,
    daysDormant: 3, openLooseEndCount: 1, score: 5,
    looseEnds: [BundleLooseEnd(text: "finish auth", quote: "we must finish the auth flow",
                               role: "user", ageDays: 3)],
    recentEvents: [BundleEvent(summary: "did the thing", kind: "cc.session", occurredAt: Date())],
    prose: prose)
}

@Test func markdownIncludesNameLooseEndAndProse() {
  let md = SessionContextRender.markdown(sampleBundle(prose: "A short recap."))
  #expect(md.contains("Pensieve"))
  #expect(md.contains("we must finish the auth flow"))
  #expect(md.contains("A short recap."))
}

@Test func markdownOmitsProseSectionWhenNil() {
  let md = SessionContextRender.markdown(sampleBundle(prose: nil))
  #expect(md.contains("we must finish the auth flow"))
  #expect(!md.lowercased().contains("last work done"))   // the prose heading is absent
}

@Test func compactIsPlainAndCitesLooseEnds() {
  let text = SessionContextRender.compact(sampleBundle(prose: nil))
  #expect(text.contains("Pensieve"))
  #expect(text.contains("we must finish the auth flow"))
}
