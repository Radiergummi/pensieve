// Sources/PensieveApp/AppModel+Translation.swift
import Foundation
import PensieveKit

extension AppModel {
  /// Translate one generated field on demand, store it, and make it findable.
  ///
  /// The write lands in `translation-cache.sqlite`, NOT the canonical store, so it cannot trip the
  /// canonical `ValueObservation` — the same shape as slice 4's Node-only writes, which needed an
  /// explicit refresh. Reindexing is therefore explicit, and debounced: translating eight loose ends
  /// in a row must not cause eight whole-corpus rebuilds.
  func translate(field: TranslationField, sourceText: String) async {
    let language = TranslationTarget.resolved()
    guard !language.isEmpty, !sourceText.isEmpty, let translator else { return }
    guard translationStore.translation(field: field, sourceText: sourceText,
                                       language: language) == nil else { return }
    guard let translated = await translator.translate(sourceText,
                                                      from: TranslationTarget.sourceLanguage,
                                                      to: language) else { return }
    translationStore.put(field: field, sourceText: sourceText, language: language, text: translated)
    translationRevision += 1   // repaint the pane with the new text — NOT a refreshToken bump (see its doc)
    await translationDebouncer.schedule()
  }

  /// The stored translation of `sourceText`, or `sourceText` itself. Never generates.
  func displayed(field: TranslationField, sourceText: String) -> String {
    let language = TranslationTarget.resolved()
    guard !language.isEmpty else { return sourceText }
    return translationStore.translation(field: field, sourceText: sourceText,
                                        language: language) ?? sourceText
  }

  /// Measure coverage off the main actor. Pre-Task locals are read here (on the main actor) rather
  /// than inside the detached closure — the same shape `AppModel+Search.runSearch` uses, INCLUDING
  /// its monotonic token, which an earlier draft of this method omitted.
  ///
  /// The token is load-bearing, not defensive: `Task.detached` does not inherit cancellation and
  /// `Task<T, Never>.value` does not throw on it, so a measurement superseded by a language switch
  /// (`.task(id: translationTarget)` in `TranslationSettingsTab`) still runs to completion and
  /// still resumes here. Landing after the newer one would latch `translationCoverage` to the OLD
  /// language, and both surfaces that read it require a language match — so the coverage line and the
  /// "Translate remaining" button would silently disappear for the rest of the Settings session.
  /// Three callers overlap this way: the `.task(id:)`, the `.onChange` cancel path, and the backfill's
  /// own completion re-measure.
  func measureTranslationCoverage() async {
    translationCoverageToken += 1
    let token = translationCoverageToken
    let language = TranslationTarget.resolved()
    guard !language.isEmpty, let database else {
      translationCoverage = nil
      return
    }
    let store = translationStore
    let measured = await Task.detached { () -> TranslationCoverage? in
      guard let units = try? TranslatableCorpus.gather(database) else { return nil }
      return TranslationCoverage.measure(units: units, store: store, language: language)
    }.value
    guard translationCoverageToken == token else { return }
    translationCoverage = measured
  }

  /// Translate everything the corpus can use and this store does not have yet.
  ///
  /// The work runs in a `Task.detached` that is stored and cancelled directly, NOT wrapped in an outer
  /// task: a detached task does not inherit cancellation, so cancelling a parent would leave the run
  /// going while the UI claimed it had stopped.
  func startTranslationBackfill() {
    guard translationBackfillRun == nil, let translator else { return }
    let language = TranslationTarget.resolved()
    // Coverage must be FOR this language, not merely present: a stale measurement from before a
    // language switch would otherwise hand this run language A's missing list to translate into
    // language B, silently skipping units A never needed. The row itself hides during that same
    // window (see `coverageRow`), so refusing here rather than measuring first keeps both in step.
    guard !language.isEmpty, let coverage = translationCoverage, coverage.language == language,
          !coverage.missing.isEmpty else { return }
    let missing = coverage.missing
    let store = translationStore
    // Built HERE, on the main actor, so `self` is captured before the detached task exists. `AppModel`
    // is `@MainActor`-isolated and therefore implicitly `Sendable`, so the weak capture crosses the
    // isolation boundary legally. There is no `AppModel.shared` in this codebase — do not add one.
    //
    // Writing through the optional makes "only while a run owns this" structural rather than a checked
    // cross-variable read: a callback arriving after the completion cleared the run is a no-op.
    let report: @Sendable (Int, Int) -> Void = { [weak self] done, _ in
      Task { @MainActor in self?.translationBackfillRun?.done = done }
    }
    let work = Task.detached {
      await TranslationBackfill.run(units: missing, store: store, translator: translator,
                                    language: language, progress: report)
    }
    translationBackfillRun = .init(task: work, language: language, done: 0, total: missing.count)
    Task { @MainActor in
      let written = await work.value
      translationBackfillRun = nil
      await measureTranslationCoverage()
      guard written > 0 else { return }
      translationRevision += 1              // repaint panes with the new text
      await translationDebouncer.schedule()  // ONE whole-corpus rebuild, not one per item
    }
  }

  /// Stops after the unit in flight. Everything already written stays; re-pressing resumes.
  func cancelTranslationBackfill() {
    translationBackfillRun?.task.cancel()
  }
}
