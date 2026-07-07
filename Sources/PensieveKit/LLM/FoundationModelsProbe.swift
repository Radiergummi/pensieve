import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A minimal, isolated probe used once to confirm on-device model availability and a
/// working round-trip on this machine. Confirm the exact API names against the current
/// Apple FoundationModels documentation — reconcile any differences here.
public enum FoundationModelsProbe {
  /// Machine-readable availability — the source of truth for provider selection. True iff the
  /// framework is importable, the OS is macOS 26+, and the model reports `.available` here.
  /// `availabilityDescription()` is for display only; decisions must not string-match it.
  public static func isAvailable() -> Bool {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      if case .available = SystemLanguageModel.default.availability { return true }
    }
    #endif
    return false
  }

  /// Human-readable availability, safe to call on any macOS (returns a reason string when
  /// the framework or model is unavailable rather than trapping).
  public static func availabilityDescription() -> String {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available:
        return "available"
      case .unavailable(let reason):
        return "unavailable: \(reason)"
      @unknown default:
        return "unavailable: unknown"
      }
    } else {
      return "unavailable: requires macOS 26"
    }
    #else
    return "unavailable: FoundationModels not importable"
    #endif
  }

  #if canImport(FoundationModels)
  @available(macOS 26.0, *)
  public static func roundTrip(_ prompt: String) async throws -> String {
    let session = LanguageModelSession()
    let response = try await session.respond(to: prompt)
    return response.content
  }
  #endif
}
