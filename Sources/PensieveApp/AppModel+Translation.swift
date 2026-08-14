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
  /// than inside the detached closure — the same shape `AppModel+Search.runSearch` uses.
  func measureTranslationCoverage() async {
    let language = TranslationTarget.resolved()
    guard !language.isEmpty, let database else {
      translationCoverage = nil
      return
    }
    let store = translationStore
    translationCoverage = await Task.detached {
      guard let units = try? TranslatableCorpus.gather(database) else { return nil }
      return TranslationCoverage.measure(units: units, store: store, language: language)
    }.value
  }

  /// Translate everything the corpus can use and this store does not have yet.
  ///
  /// The work runs in a `Task.detached` that is stored and cancelled directly, NOT wrapped in an outer
  /// task: a detached task does not inherit cancellation, so cancelling a parent would leave the run
  /// going while the UI claimed it had stopped.
  func startTranslationBackfill() {
    guard translationBackfillTask == nil, let translator else { return }
    let language = TranslationTarget.resolved()
    guard !language.isEmpty, let missing = translationCoverage?.missing, !missing.isEmpty else { return }
    let store = translationStore
    translationBackfillProgress = (done: 0, total: missing.count)
    // Built HERE, on the main actor, so `self` is captured before the detached task exists. `AppModel`
    // is `@MainActor`-isolated and therefore implicitly `Sendable`, so the weak capture crosses the
    // isolation boundary legally. There is no `AppModel.shared` in this codebase — do not add one.
    let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
      Task { @MainActor in
        // Only while this run still owns the progress: a completion that already cleared it must not
        // be re-populated by a late callback.
        guard let self, self.translationBackfillTask != nil else { return }
        self.translationBackfillProgress = (done: done, total: total)
      }
    }
    let work = Task.detached {
      await TranslationBackfill.run(units: missing, store: store, translator: translator,
                                    language: language, progress: report)
    }
    translationBackfillTask = work
    Task { @MainActor in
      let written = await work.value
      translationBackfillTask = nil
      translationBackfillProgress = nil
      await measureTranslationCoverage()
      guard written > 0 else { return }
      translationRevision += 1              // repaint panes with the new text
      await translationDebouncer.schedule()  // ONE whole-corpus rebuild, not one per item
    }
  }

  /// Stops after the unit in flight. Everything already written stays; re-pressing resumes.
  func cancelTranslationBackfill() {
    translationBackfillTask?.cancel()
  }
}
