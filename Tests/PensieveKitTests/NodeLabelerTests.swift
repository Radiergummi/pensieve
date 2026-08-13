import Testing
@testable import PensieveKit

/// Returns a fixed label. The marker text is deliberately distinctive so a test can assert the
/// model was NOT consulted by checking the result is something else.
private struct StubLabelLLM: LLMProvider {
  let text: String
  func complete(prompt: String) async throws -> String { text }
}

private struct FailingLabelLLM: LLMProvider {
  func complete(prompt: String) async throws -> String { throw LLMError.providerFailed("nope") }
}

@Test func englishInputUsesTheModelsLabel() async {
  let label = await NodeLabeler.label(for: "look into why the background sync agent stopped spawning",
                                      provider: StubLabelLLM(text: "Background Sync Agent Issue"))
  #expect(label == "Background Sync Agent Issue")
}

@Test func germanInputNeverReachesTheModel() async {
  // The decisive routing test. The provider would return this marker if consulted; the German
  // arm must return the deterministic shortening of the user's own words instead. Measured
  // rationale: the on-device model translates German, once returning "Train Advertisement Claim"
  // for a delayed-train complaint, and a "do not translate" instruction does not fix it.
  let typed = "die Bahn-Reklamation für die verspätete Fahrt einreichen"
  let label = await NodeLabeler.label(for: typed, provider: StubLabelLLM(text: "MODEL-WAS-CONSULTED"))
  #expect(label != "MODEL-WAS-CONSULTED")
  #expect(label == TextQuality.shorten(typed))
}

@Test func everyModelFailureFallsBackToTheDeterministicLabel() async {
  let typed = "migrate the loose end resolution verbs into the CLI"
  let expected = TextQuality.shorten(typed)

  // A throwing provider.
  #expect(await NodeLabeler.label(for: typed, provider: FailingLabelLLM()) == expected)
  // No provider at all.
  #expect(await NodeLabeler.label(for: typed, provider: nil) == expected)
  // Empty output.
  #expect(await NodeLabeler.label(for: typed, provider: StubLabelLLM(text: "   ")) == expected)
  // Output the gate rejects: multi-sentence, and over the cap.
  #expect(await NodeLabeler.label(for: typed,
                                  provider: StubLabelLLM(text: "Migrate the verbs. Then update the CLI")) == expected)
  #expect(await NodeLabeler.label(
    for: typed,
    provider: StubLabelLLM(text: String(repeating: "long ", count: 30))) == expected)
}

@Test func onlyEmptyInputYieldsNil() async {
  #expect(await NodeLabeler.label(for: "", provider: nil) == nil)
  #expect(await NodeLabeler.label(for: "   \n ", provider: nil) == nil)
}

@Test func languageRoutingMatchesTheMeasuredProbe() {
  #expect(NodeLabeler.isEnglish("look into why the background sync agent stopped spawning"))
  #expect(NodeLabeler.isEnglish("fix the German truncation in the menu bar footer"))
  #expect(!NodeLabeler.isEnglish("Steuerunterlagen für 2025 zusammenstellen"))
  #expect(!NodeLabeler.isEnglish("Geschenk für Mamas Geburtstag besorgen"))
  // Undetectable input must take the safe (deterministic) arm, not the model.
  #expect(!NodeLabeler.isEnglish(""))
}
