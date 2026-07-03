import Foundation
import Testing
@testable import PensieveKit

@Test func claudeProviderUsesInjectedRunner() async throws {
  let provider = ClaudeCLIProvider(run: { prompt in "echo: \(prompt)" })
  let out = try await provider.complete(prompt: "hello")
  #expect(out == "echo: hello")
}
