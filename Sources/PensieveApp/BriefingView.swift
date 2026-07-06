// Sources/PensieveApp/BriefingView.swift
import SwiftUI
import PensieveKit

/// The default landing: a by-project "world map" — what moved since your last visit, and each
/// project's most-outstanding loose end. Clicking a card drills into that project's detail.
struct BriefingView: View {
  @ObservedObject var model: AppModel

  private var moved: [BriefingCard] { model.briefingCards.filter { $0.movedSince > 0 } }
  private var quiet: [BriefingCard] { model.briefingCards.filter { $0.movedSince == 0 } }

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
        if !quiet.isEmpty {
          section("Quiet") { ForEach(quiet) { card(for: $0) } }
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func card(for c: BriefingCard) -> some View {
    Button { model.selectedNodeID = c.node.id } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(c.node.name).font(.headline)
          Spacer()
          if c.movedSince > 0 {
            Text("\(c.movedSince) since last visit").font(.caption).foregroundStyle(.secondary)
          } else {
            Text("dormant \(c.daysDormant)d").font(.caption).foregroundStyle(.tertiary)
          }
        }
        if !c.latestSummary.isEmpty {
          Text(c.latestSummary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        if let top = c.topLooseEnd {
          Label(top, systemImage: "arrow.right.circle").font(.caption).foregroundStyle(.orange).lineLimit(1)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder private func section(_ title: LocalizedStringResource, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(String(localized: title).uppercased()).font(.caption).bold().foregroundStyle(.secondary)
      content()
    }
  }
}
