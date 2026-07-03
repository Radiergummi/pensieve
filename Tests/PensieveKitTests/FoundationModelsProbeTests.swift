import Foundation
import Testing
@testable import PensieveKit

@Test func foundationModelsAvailabilityIsReported() {
  let desc = FoundationModelsProbe.availabilityDescription()
  print("FoundationModels availability: \(desc)")
  #expect(!desc.isEmpty)
}

@Test func foundationModelsRoundTripIfAvailable() async throws {
  guard FoundationModelsProbe.availabilityDescription() == "available" else {
    print("skipping round-trip: model unavailable")
    return
  }
  if #available(macOS 26.0, *) {
    let out = try await FoundationModelsProbe.roundTrip("Reply with the single word: ok")
    print("FoundationModels round-trip output: \(out)")
    #expect(!out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}
