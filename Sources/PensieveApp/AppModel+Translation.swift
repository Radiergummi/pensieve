// Sources/PensieveApp/AppModel+Translation.swift
import Foundation
import PensieveKit

extension AppModel {
  /// What started a `TranslationBackfillRun`. A manual run must never be cancelled for "the user came
  /// back" — they pressed the button — so the per-unit yield is conditional on this.
  ///
  /// Declared at this level, a sibling of `TranslationBackfillRun` rather than nested inside it, so it
  /// stays within SwiftLint's one-level type-nesting limit — the same reasoning that keeps `HookInput`
  /// at file scope in `CaptureSessionStart.swift`: nesting `enum CodingKeys` inside a type that was
  /// itself nested would be two levels deep.
  enum TranslationBackfillTrigger: Sendable { case manual, automatic }

  /// A bulk translation in flight: the task and its progress as ONE value, not two kept in step by
  /// convention. The invariant "progress is non-nil exactly while a task exists" was previously
  /// asserted in three doc comments and enforced nowhere — it held only because nothing had yet been
  /// inserted between the two assignments. It also split authority: the view chose its branch from the
  /// progress but its Stop button acted on the task. Two copies of one fact is how they stop agreeing,
  /// which is the same argument `SearchHitResolver` and `EmbeddableCorpus.corpusNodes` exist on.
  struct TranslationBackfillRun {
    /// `Task.detached` deliberately — see `startTranslationBackfill`.
    let task: Task<Int, Never>
    /// The language this run translates INTO. Cancellation is cooperative, so a run outlives the
    /// language switch that cancelled it by however long its in-flight unit takes; without this tag
    /// the progress row rendered under the NEWLY selected language, claiming work toward a target
    /// this run is not translating into. Every other piece of translation state on this branch
    /// carries its language for exactly this reason — `TranslationCoverage.language` and
    /// `TranslationSettingsTab.downloadingLanguage` — and this was the one that did not.
    let language: String
    let trigger: TranslationBackfillTrigger
    var done: Int
    let total: Int
  }

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
  func startTranslationBackfill(trigger: TranslationBackfillTrigger = .manual) {
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
      Task { @MainActor in
        guard let self else { return }
        self.translationBackfillRun?.done = done
        // Read the trigger off the LIVE run rather than the captured parameter, for the same reason
        // `done` is written through the optional: a callback that arrives after the run it belongs to
        // has gone must be a no-op, not an act on whatever is there now.
        guard self.translationBackfillRun?.trigger == .automatic,
              !IdleTranslationPolicy.shouldContinue(IdleSensors.conditions(language: language))
        else { return }
        AppLog.app.info("Idle translation yielding after \(done, privacy: .public) unit(s)")
        self.cancelTranslationBackfill()
      }
    }
    let work = Task.detached {
      await TranslationBackfill.run(units: missing, store: store, translator: translator,
                                    language: language, progress: report)
    }
    translationBackfillRun = .init(task: work, language: language, trigger: trigger,
                                   done: 0, total: missing.count)
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

  /// Translate whatever is missing, unasked, because the Mac is idle.
  ///
  /// Deliberately a composition of two methods that already exist rather than a second execution
  /// path. It claims the SAME `translationBackfillRun` slot the button does, which is what makes the
  /// Settings progress row, its Stop button, the disabled state of "Translate remaining" and
  /// cancellation on a language switch all work for an automatic run with no new UI at all.
  ///
  /// `measureTranslationCoverage()` is reused rather than reimplemented because it produces exactly
  /// what is needed — a `TranslationCoverage` carrying its language and its `missing` work list —
  /// and because measuring through the one method keeps the coverage Settings would show and the
  /// coverage this acts on the same value. The await between measuring and starting is safe:
  /// `startTranslationBackfill` re-checks every precondition after it.
  ///
  /// - Returns: whether a pass actually started, so the scheduler can distinguish work done from a
  ///   refusal and report `.finished` versus `.deferred`.
  @discardableResult
  func runIdleTranslationPass() async -> Bool {
    let language = TranslationTarget.resolved()
    let conditions = IdleSensors.conditions(language: language)
    // The cheap half first, purely to avoid paying for the availability probe below on a machine the
    // user is actively using. `shouldStart` re-checks it; this guard is an optimization, not a rule.
    guard IdleTranslationPolicy.shouldContinue(conditions) else { return false }
    let isPackInstalled = await IdleSensors.isPackInstalled(language: language)
    guard IdleTranslationPolicy.shouldStart(conditions, isPackInstalled: isPackInstalled,
                                            isRunInFlight: translationBackfillRun != nil)
    else { return false }

    await measureTranslationCoverage()
    startTranslationBackfill(trigger: .automatic)
    // Not `true`: `startTranslationBackfill` still refuses a coverage with nothing missing, which is
    // the common case once the corpus has caught up.
    let started = translationBackfillRun != nil
    if started { AppLog.app.info("Idle translation pass started") }
    return started
  }
}
