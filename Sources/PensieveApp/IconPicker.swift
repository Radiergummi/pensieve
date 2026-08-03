// Sources/PensieveApp/IconPicker.swift
import SwiftUI
import PensieveKit

/// Emoji grouped into the picker's bottom-tab categories, generated from Unicode scalar ranges and
/// filtered to single-scalar emoji-presentation characters (skips ZWJ sequences — a solid, common set).
enum EmojiCatalog {
  struct Category: Identifiable { let id: String; let symbol: String; let emoji: [String] }

  private static func build(_ ranges: [ClosedRange<UInt32>]) -> [String] {
    var out: [String] = []
    for r in ranges {
      for v in r {
        guard let scalar = Unicode.Scalar(v) else { continue }
        let props = scalar.properties
        if props.isEmoji && props.isEmojiPresentation { out.append(String(scalar)) }
      }
    }
    return out
  }

  static let categories: [Category] = [
    Category(id: "smileys", symbol: "face.smiling", emoji: build([0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97A])),
    Category(id: "people", symbol: "person", emoji: build([0x1F464...0x1F487, 0x1F9D0...0x1F9DF])),
    Category(id: "nature", symbol: "leaf", emoji: build([0x1F400...0x1F43E, 0x1F980...0x1F9AE, 0x1F330...0x1F344])),
    Category(id: "food", symbol: "fork.knife", emoji: build([0x1F345...0x1F37F, 0x1F950...0x1F96F])),
    Category(id: "activity", symbol: "soccerball", emoji: build([0x1F3A0...0x1F3CA, 0x1F93C...0x1F93E])),
    Category(id: "travel", symbol: "car", emoji: build([0x1F680...0x1F6C5, 0x1F3E0...0x1F3F0])),
    Category(id: "objects", symbol: "lightbulb", emoji: build([0x1F4A1...0x1F4FF, 0x1F526...0x1F52F])),
    Category(id: "symbols", symbol: "heart", emoji: build([0x2600...0x26FF, 0x1F532...0x1F53D])),
  ]

  /// A lowercase Unicode name for search, e.g. "😀" → "grinning face". Uses the system transform.
  static func name(of emoji: String) -> String {
    let t = emoji.applyingTransform(.toUnicodeName, reverse: false) ?? ""
    return t.replacingOccurrences(of: "\\N{", with: "").replacingOccurrences(of: "}", with: "").lowercased()
  }
}

/// The "Symbol:" two-button row: an emoji toggle + a symbol toggle, each opening an anchored picker
/// popover. `icon` is the stored form ("emoji:<g>" / "sf:<name>"); writing either sets it.
struct IconToggleRow: View {
  @Binding var icon: String
  var tint: Color
  @State private var showEmoji = false
  @State private var showSymbol = false

  private var isEmoji: Bool { if case .emoji = AppearanceIcon.parse(icon) { return true }; return false }
  private var currentEmoji: String? { if case .emoji(let e) = AppearanceIcon.parse(icon) { return e }; return nil }
  private var currentSymbol: String? { if case .sfSymbol(let n) = AppearanceIcon.parse(icon) { return n }; return nil }

  var body: some View {
    HStack(spacing: 12) {
      // Emoji toggle
      Button { showEmoji = true } label: {
        ZStack {
          Circle().fill(isEmoji ? tint.opacity(0.25) : Color.secondary.opacity(0.15))
          if let e = currentEmoji { Text(e).font(.system(size: 22)) } else { Image(systemName: "face.smiling").font(.system(size: 20)).foregroundStyle(.secondary) }
        }.frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .popover(isPresented: $showEmoji, arrowEdge: .bottom) {
        EmojiPickerPopover { icon = "emoji:\($0)"; showEmoji = false }
      }
      // Symbol toggle
      Button { showSymbol = true } label: {
        ZStack {
          Circle().fill(!isEmoji ? tint : Color.secondary.opacity(0.15))
          Image(systemName: currentSymbol ?? "list.bullet")
            .font(.system(size: 20)).foregroundStyle(!isEmoji ? .white : .secondary)
        }.frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .popover(isPresented: $showSymbol, arrowEdge: .bottom) {
        SymbolPickerPopover(selected: currentSymbol) { icon = "sf:\($0)"; showSymbol = false }
      }
    }
  }
}

/// Search + category-tab emoji grid, anchored under the emoji toggle.
struct EmojiPickerPopover: View {
  let onPick: (String) -> Void
  @State private var query = ""
  @State private var category = EmojiCatalog.categories.first!.id

  private var shown: [String] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    if !q.isEmpty {
      return EmojiCatalog.categories.flatMap(\.emoji).filter { EmojiCatalog.name(of: $0).contains(q) }
    }
    return EmojiCatalog.categories.first { $0.id == category }?.emoji ?? []
  }

  var body: some View {
    VStack(spacing: 8) {
      TextField("Search", text: $query).textFieldStyle(.roundedBorder)
      ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 6), spacing: 6) {
          ForEach(shown, id: \.self) { e in
            Button { onPick(e) } label: { Text(e).font(.system(size: 24)) }.buttonStyle(.plain)
          }
        }
      }.frame(height: 220)
      if query.isEmpty {
        HStack(spacing: 4) {
          ForEach(EmojiCatalog.categories) { c in
            Button { category = c.id } label: {
              Image(systemName: c.symbol).font(.system(size: 13))
                .foregroundStyle(category == c.id ? Color.accentColor : .secondary)
            }.buttonStyle(.plain).frame(maxWidth: .infinity)
          }
        }
      }
    }
    .padding(10).frame(width: 300)
  }
}

/// Search + round-tinted SF-symbol grid, anchored under the symbol toggle. Selected symbol ringed.
struct SymbolPickerPopover: View {
  let selected: String?
  let onPick: (String) -> Void
  @State private var query = ""

  private var shown: [String] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    return q.isEmpty ? Self.symbols : Self.symbols.filter { $0.contains(q) }
  }

  var body: some View {
    VStack(spacing: 8) {
      TextField("Search symbols", text: $query).textFieldStyle(.roundedBorder)
      ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 6), spacing: 8) {
          ForEach(shown, id: \.self) { name in
            Button { onPick(name) } label: {
              ZStack {
                Circle().fill(Color.secondary.opacity(0.15))
                Image(systemName: name).font(.system(size: 16)).foregroundStyle(.primary)
              }
              .frame(width: 34, height: 34)
              .overlay { if selected == name { Circle().stroke(Color.accentColor, lineWidth: 2) } }
            }.buttonStyle(.plain)
          }
        }
      }.frame(height: 240)
    }
    .padding(10).frame(width: 300)
  }

  // The curated SF-symbol set (moved from NodeEditor.symbols).
  static let symbols = [
    "folder", "folder.badge.gearshape", "shippingbox", "arrow.triangle.branch", "lightbulb",
    "flag", "flag.checkered", "checklist", "list.bullet", "tag", "star", "sparkles", "bolt",
    "book", "books.vertical", "hammer", "wrench.and.screwdriver", "paintbrush", "paintpalette",
    "cart", "gearshape", "gearshape.2", "doc.text", "doc.richtext", "calendar", "clock", "person",
    "person.2", "house", "building.2", "globe", "network", "leaf", "cup.and.saucer",
    "gamecontroller", "music.note", "camera", "photo", "terminal", "cpu", "server.rack",
    "chart.bar", "chart.line.uptrend.xyaxis", "envelope", "message", "bubble.left", "map",
    "location", "heart", "flame", "drop", "wand.and.stars", "puzzlepiece", "cube", "shield",
    "lock", "key", "brain", "graduationcap", "briefcase", "creditcard", "banknote",
  ]
}
