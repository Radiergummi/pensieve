import Foundation

/// The user's LLM-provider choice. `.auto` = today's local-first behavior (Foundation Models
/// when available on this machine, else `claude -p`). Raw values are the stable on-disk strings.
public enum ProviderPreference: String, Sendable, Codable {
  case auto
  case foundationModels
  case claudeCLI
}

/// Machine-local settings persisted as a small JSON file in the shared (non-sandboxed) support
/// dir, so BOTH the app and the launchd daemon read the same choice. Reads are best-effort and
/// never throw into a caller: a missing, unreadable, corrupt, or unknown value ⇒ `.auto`.
/// Callers pass an explicit URL (tests inject a temp path; the app/CLI resolve it once via the
/// factory below) — this type deliberately does not read the environment.
public enum Preferences {
  private struct Payload: Codable { var llmProvider: String? }

  public static func read(from url: URL) -> ProviderPreference {
    guard let data = try? Data(contentsOf: url),
          let payload = try? JSONDecoder().decode(Payload.self, from: data),
          let raw = payload.llmProvider,
          let preference = ProviderPreference(rawValue: raw)
    else { return .auto }
    return preference
  }

  public static func write(_ preference: ProviderPreference, to url: URL) {
    guard let data = try? JSONEncoder().encode(Payload(llmProvider: preference.rawValue))
    else { return }
    try? PensievePaths.ensureParentDirectory(of: url)
    try? data.write(to: url, options: .atomic)
  }
}
