import Foundation
import Testing
@testable import PensieveKit

private func sampleBundle(prose: String?) -> ProjectContextBundle {
  ProjectContextBundle(
    nodeID: UUID(), name: "Pensieve", kind: NodeKind.project,
    description: "context reconstruction tool", context: NodeContext.work,
    daysDormant: 3, openLooseEndCount: 1, score: 5,
    looseEnds: [BundleLooseEnd(id: UUID(), text: "finish auth", quote: "we must finish the auth flow",
                               role: "user", ageDays: 3)],
    recentEvents: [BundleEvent(summary: "did the thing", kind: "cc.session", occurredAt: Date())],
    prose: prose)
}

@Test func markdownIncludesNameLooseEndAndProse() {
  let markdown = SessionContextRender.markdown(sampleBundle(prose: "A short recap."))
  #expect(markdown.contains("Pensieve"))
  #expect(markdown.contains("we must finish the auth flow"))
  #expect(markdown.contains("A short recap."))
}

@Test func markdownOmitsProseSectionWhenNil() {
  let markdown = SessionContextRender.markdown(sampleBundle(prose: nil))
  #expect(markdown.contains("we must finish the auth flow"))
  #expect(!markdown.lowercased().contains("last work done"))   // the prose heading is absent
}

@Test func compactIsPlainAndCitesLooseEnds() {
  let text = SessionContextRender.compact(sampleBundle(prose: nil))
  #expect(text.contains("Pensieve"))
  #expect(text.contains("we must finish the auth flow"))
}

private func bundleWithLooseEnds(_ count: Int) -> ProjectContextBundle {
  ProjectContextBundle(
    nodeID: UUID(), name: "Pensieve", kind: NodeKind.project, description: "", context: "",
    daysDormant: 0, openLooseEndCount: count, score: 0,
    looseEnds: (0..<count).map { BundleLooseEnd(id: UUID(), text: "end \($0)", quote: "q\($0)", role: "user", ageDays: 0) },
    recentEvents: [], prose: nil)
}

@Test func compactCapsLooseEndsWithATail() {
  let text = SessionContextRender.compact(bundleWithLooseEnds(20), maxLooseEnds: 8)
  #expect(text.contains("end 0"))
  #expect(text.contains("end 7"))
  #expect(!text.contains("end 8"))        // capped
  #expect(text.contains("… and 12 more"))
}

@Test func compactNoTailWhenUnderCap() {
  let text = SessionContextRender.compact(bundleWithLooseEnds(3), maxLooseEnds: 8)
  #expect(text.contains("end 2"))
  #expect(!text.contains("more"))
}

@Test func whatsNextRendersRankedRowsWithCitations() {
  let items = [
    WhatsNextItem(nodeID: UUID(), name: "Alpha", kind: NodeKind.project,
                  openLooseEnds: 3, daysDormant: 5, score: 11, topLooseEnd: "ship the thing"),
    WhatsNextItem(nodeID: UUID(), name: "Beta", kind: NodeKind.strand,
                  openLooseEnds: 0, daysDormant: 2, score: 2, topLooseEnd: nil),
  ]
  let markdown = SessionContextRender.whatsNext(items)
  #expect(markdown.contains("# What's Next"))
  #expect(markdown.contains("**Alpha** — 3 open, 5d dormant"))
  #expect(markdown.contains("> ship the thing"))
  #expect(markdown.contains("**Beta** — 0 open, 2d dormant"))
}

@Test func whatsNextEmptyIsJustTheHeader() {
  #expect(SessionContextRender.whatsNext([]) == "# What's Next\n\n")
}
