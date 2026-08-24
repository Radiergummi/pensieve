// Sources/PensieveApp/BriefingView.swift
import SwiftUI
import PensieveKit

/// The default landing: a by-project "world map" — what moved since your last visit, and each
/// project's most-outstanding loose end. Clicking a card drills into that project's detail.
struct BriefingView: View {
  var model: AppModel
  @AppStorage("briefing.quiet.expanded") private var quietExpanded = false

  // The two buckets are partitioned once, where the cards are loaded (`AppModel.loadBriefingCards`),
  // not here: these were computed properties, so every observation change re-filtered the whole card
  // set twice inside `body`.
  private var moved: [BriefingCard] { model.briefingMoved }
  private var quiet: [BriefingCard] { model.briefingQuiet }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Since \(model.briefingSince, format: .dateTime.weekday(.wide).month().day())")
          .font(.largeTitle).bold()

        if model.briefingCards.isEmpty {
          Text("No captured activity yet.").foregroundStyle(.secondary)
        }

        if !moved.isEmpty {
          section("Moved") { ForEach(moved) { card(for: $0) } }
        }
        // Quiet projects get one line each, collapsed. Visual mass should track importance, and five
        // dormant projects rendered as full cards outweigh the one that actually moved.
        if !quiet.isEmpty {
          DisclosureGroup(isExpanded: $quietExpanded) {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(quiet) { quietRow(for: $0) }
            }
          } label: {
            Text("Quiet").sectionHeader()
          }
        }
      }
      .padding(24)
      .frame(maxWidth: Prose.measure, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)   // center the capped reading column in a wide pane
    }
  }

  private func card(for briefingCard: BriefingCard) -> some View {
    Button { model.selectedNodeID = briefingCard.node.id } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(briefingCard.node.name).font(.headline)
          Spacer()
          // `card(for:)` now renders ONLY moved projects, so the dormant branch is gone with its
          // `dormant %lldd` string — which never matched its `dormant %@d` catalog key anyway.
          Text("\(briefingCard.movedSince) new").metaText().monospacedDigit()
        }
        if !briefingCard.latestSummary.isEmpty {
          Text(briefingCard.latestSummary).prose().foregroundStyle(.secondary).lineLimit(1)
        }
        if let top = briefingCard.topLooseEnd {
          Label(top, systemImage: "arrow.right.circle").font(.system(size: 12)).foregroundStyle(.orange).lineLimit(1)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
  }

  /// One quiet project: name, and how long ago it was last touched. Deliberately a bare relative
  /// date and not "dormant for N days" — the section header already says these are quiet, and the
  /// bare date is the only phrasing here that needs no plural rule in either language.
  private func quietRow(for briefingCard: BriefingCard) -> some View {
    Button { model.selectedNodeID = briefingCard.node.id } label: {
      HStack(spacing: 8) {
        NodeBadge(node: briefingCard.node, size: 16)
        Text(briefingCard.node.name).font(.system(size: 13))
        Spacer()
        NodeMeta.recency(briefingCard.lastActivityAt)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder private func section(_ title: LocalizedStringResource, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).sectionHeader()
      content()
    }
  }
}
