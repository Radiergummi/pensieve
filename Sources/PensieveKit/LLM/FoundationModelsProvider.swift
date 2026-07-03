import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// Default provider: on-device Apple model. No API key, no rate limits, no subprocess.
@available(macOS 26.0, *)
public struct FoundationModelsProvider: LLMProvider {
  public init() {}

  public func complete(prompt: String) async throws -> String {
    let session = LanguageModelSession()
    do {
      let response = try await session.respond(to: prompt)
      return response.content
    } catch {
      throw LLMError.providerFailed("FoundationModels: \(error)")
    }
  }
}
#endif
