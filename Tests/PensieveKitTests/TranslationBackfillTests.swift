import Testing
import Foundation
@testable import PensieveKit

@Suite struct TranslationBackfillTests {
  /// Records every call, so negative assertions ("it did not call the translator again") are real
  /// rather than inferred from the store. Same shape as `TranslatedSearchTests.RecordingTranslator`.
  private actor RecordingTranslator: Translator {
    private(set) var calls: [String] = []
    private let prefix: String
    private let returnsNil: Bool
    init(prefix: String = "de:", returnsNil: Bool = false) {
      self.prefix = prefix
      self.returnsNil = returnsNil
    }
    func translate(_ text: String, from source: String, to target: String) async -> String? {
      calls.append(text)
      return returnsNil ? nil : prefix + text
    }
    func callCount() -> Int { calls.count }
  }

  /// Parks inside the first `translate` call until the test opens the gate, so cancellation lands at
  /// a KNOWN point. Without this the loop can finish before `cancel()` is observed, and the test
  /// passes or fails by scheduling luck.
  private actor GateTranslator: Translator {
    private(set) var calls: [String] = []
    private var arrived: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func translate(_ text: String, from source: String, to target: String) async -> String? {
      calls.append(text)
      arrived?.resume()
      arrived = nil
      if !isOpen {
        await withCheckedContinuation { continuation in release = continuation }
      }
      return "de:" + text
    }

    /// Returns once the run has entered its first `translate`.
    func waitForFirstCall() async {
      guard calls.isEmpty else { return }
      await withCheckedContinuation { continuation in arrived = continuation }
    }

    /// Lets the parked call finish, and stops parking later ones.
    func open() {
      isOpen = true
      release?.resume()
      release = nil
    }

    func callCount() -> Int { calls.count }
  }

  private let units = [TranslatableUnit(field: .nodeName, sourceText: "one"),
                       TranslatableUnit(field: .nodeName, sourceText: "two"),
                       TranslatableUnit(field: .looseEndText, sourceText: "three")]

  @Test func writesEveryMissingUnitAndReportsProgress() async {
    let store = TranslationStore(url: tempURL("backfill-writes"))
    let translator = RecordingTranslator()
    let reported = Reported()
    let written = await TranslationBackfill.run(units: units, store: store, translator: translator,
                                                language: "de") { done, total in
      reported.record(done: done, total: total)
    }
    #expect(written == 3)
    #expect(store.translation(field: .nodeName, sourceText: "two", language: "de") == "de:two")
    #expect(store.translation(field: .looseEndText, sourceText: "three", language: "de") == "de:three")
    #expect(reported.pairs.map(\.0) == [1, 2, 3])
    #expect(reported.pairs.allSatisfy { $0.1 == 3 })
  }

  /// Idempotence — the property the eval generator lacked, which is why it could not be re-run after
  /// dying at 522/870. A second press must pay only for what is missing.
  ///
  /// FAILS UNDER MUTATION: remove the check-then-skip guard.
  @Test func aSecondRunTranslatesNothing() async {
    let store = TranslationStore(url: tempURL("backfill-idempotent"))
    let first = RecordingTranslator()
    _ = await TranslationBackfill.run(units: units, store: store, translator: first,
                                      language: "de", progress: { _, _ in })
    let second = RecordingTranslator()
    let written = await TranslationBackfill.run(units: units, store: store, translator: second,
                                                language: "de", progress: { _, _ in })
    #expect(written == 0)
    #expect(await second.callCount() == 0)
  }

  /// Cancellation stops the run and keeps what already landed. Deterministic via `GateTranslator`.
  ///
  /// FAILS UNDER MUTATION: remove the `Task.isCancelled` check — call count becomes 3.
  @Test func cancellationKeepsWhatLandedAndStops() async {
    let store = TranslationStore(url: tempURL("backfill-cancel"))
    let translator = GateTranslator()
    let work = Task {
      await TranslationBackfill.run(units: units, store: store, translator: translator,
                                    language: "de", progress: { _, _ in })
    }
    await translator.waitForFirstCall()   // parked inside unit 1
    work.cancel()
    await translator.open()               // let unit 1 finish; the loop then sees the cancellation
    let written = await work.value

    #expect(written == 1)
    #expect(await translator.callCount() == 1)
    #expect(store.translation(field: .nodeName, sourceText: "one", language: "de") == "de:one")
    #expect(store.translation(field: .nodeName, sourceText: "two", language: "de") == nil)
  }

  /// A nil is skipped, counted as attempted, and NOT retried within the run — an absent language pack
  /// nils every call, and 1,294 retries of a condition that cannot change mid-run is a hang wearing a
  /// progress bar. A later run tries again, which is honest: the pack may since have installed.
  @Test func nilTranslationsAreSkippedNotRetried() async {
    let store = TranslationStore(url: tempURL("backfill-nil"))
    let translator = RecordingTranslator(returnsNil: true)
    let written = await TranslationBackfill.run(units: units, store: store, translator: translator,
                                                language: "de", progress: { _, _ in })
    #expect(written == 0)
    #expect(await translator.callCount() == 3)
    #expect(store.translation(field: .nodeName, sourceText: "one", language: "de") == nil)
  }

  /// Off means off: no translator call, no store write.
  @Test func offTranslatesNothing() async {
    let store = TranslationStore(url: tempURL("backfill-off"))
    let translator = RecordingTranslator()
    let written = await TranslationBackfill.run(units: units, store: store, translator: translator,
                                                language: TranslationTarget.off,
                                                progress: { _, _ in })
    #expect(written == 0)
    #expect(await translator.callCount() == 0)
  }

  /// Collects progress callbacks. A plain `final class` guarded by the test's own single-threaded use;
  /// `@unchecked Sendable` because the callback is `@Sendable` but the run is serial by construction.
  private final class Reported: @unchecked Sendable {
    private(set) var pairs: [(Int, Int)] = []
    func record(done: Int, total: Int) { pairs.append((done, total)) }
  }
}
