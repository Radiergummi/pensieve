import AppIntents
import AppKit
import PensieveKit

/// The three smart lists as an intent parameter. Raw values match `DeepLink.SmartList` so the mapping
/// below is a pure re-label; the exhaustive switch fails to compile if a case is ever added (no drift).
enum PensieveListOption: String, AppEnum {
  case whatsNext, dormant, recentlyActive

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pensieve List")
  static let caseDisplayRepresentations: [PensieveListOption: DisplayRepresentation] = [
    .whatsNext: "What's Next",
    .dormant: "Dormant",
    .recentlyActive: "Recently Active",
  ]

  var deepLinkKind: DeepLink.SmartList {
    switch self {
    case .whatsNext: return .whatsNext
    case .dormant: return .dormant
    case .recentlyActive: return .recentlyActive
    }
  }
}

/// Hands a resolved deep link to the shared AppDelegate bridge — the same path external `pensieve://`
/// opens use. Must run on the main actor (touches NSApp). Fire-and-forget w.r.t. navigation.
enum PensieveIntentBridge {
  @MainActor static func route(_ link: DeepLink) {
    (NSApp.delegate as? AppDelegate)?.receive(link)
  }
}

/// Open a specific node's recall view. `OpenIntent` implies opening the app. The system resolves
/// `target` via NodeEntityQuery BEFORE perform() runs; a deleted id → perform() never runs (silent).
struct OpenNodeIntent: OpenIntent {
  static let title: LocalizedStringResource = "Open Node"
  @Parameter(title: "Node") var target: NodeEntity

  @MainActor func perform() async throws -> some IntentResult {
    PensieveIntentBridge.route(.node(target.id))
    return .result()
  }
}

/// Open one of the three smart lists (What's Next / Dormant / Recently Active).
struct ShowPensieveListIntent: AppIntent {
  static let title: LocalizedStringResource = "Show Pensieve List"
  static let openAppWhenRun = true
  @Parameter(title: "List") var list: PensieveListOption

  @MainActor func perform() async throws -> some IntentResult {
    PensieveIntentBridge.route(.smartList(list.deepLinkKind))
    return .result()
  }
}
