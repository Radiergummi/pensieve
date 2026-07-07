import AppIntents
import Foundation
import PensieveKit

/// Where the active Focus context is persisted (single process — no App Group). "" = no filter.
enum FocusFilterDefaults {
  static let activeContextKey = "pensieve.activeFocusContext"
}

/// The two explicit contexts, as a Focus-filter parameter. Raw values match `NodeContext` constants;
/// the exhaustive `nodeContext` switch fails to compile if a case is added (no drift).
enum FocusContextOption: String, AppEnum {
  case work, personal

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pensieve Context")
  static let caseDisplayRepresentations: [FocusContextOption: DisplayRepresentation] = [
    .work: "Work", .personal: "Personal",
  ]

  var nodeContext: String {
    switch self {
    case .work: return NodeContext.work
    case .personal: return NodeContext.personal
    }
  }
}

/// Attach in System Settings → Focus → (a Focus) → Add Filter → Pensieve, then pick a context. On
/// activation the system sets `context`; on deactivation it re-runs perform() with `context == nil`
/// (why the parameter is OPTIONAL — a non-optional one is only delivered on activation). perform()
/// persists the active context; AppModel observes the change and re-filters + reindexes.
struct PensieveFocusFilter: SetFocusFilterIntent {
  static let title: LocalizedStringResource = "Filter Pensieve by Context"

  @Parameter(title: "Context") var context: FocusContextOption?

  var displayRepresentation: DisplayRepresentation {
    switch context {
    case .work: return DisplayRepresentation(title: "Show Work")
    case .personal: return DisplayRepresentation(title: "Show Personal")
    case nil: return DisplayRepresentation(title: "Show All")
    }
  }

  @MainActor func perform() async throws -> some IntentResult {
    UserDefaults.standard.set(context?.nodeContext ?? "", forKey: FocusFilterDefaults.activeContextKey)
    return .result()
  }
}
