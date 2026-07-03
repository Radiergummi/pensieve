import Foundation

public enum LLMError: Error, Sendable { case providerFailed(String) }

/// The single narrow seam through which all model calls flow. Deliberately minimal:
/// one method, prompt in / text out. Structured output is achieved by prompting for
/// JSON and decoding at the call site, so any provider (local or HTTP) satisfies it.
public protocol LLMProvider: Sendable {
  func complete(prompt: String) async throws -> String
}
