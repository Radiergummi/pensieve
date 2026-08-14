import Foundation

/// Translates the corpus that on-demand translation left behind.
///
/// On-demand translation is the steady state for text you are looking at; it is not a way to get a
/// corpus translated. Measured on 2026-08-14: 2 stored translations against 1,294 translatable texts,
/// with `nodeName` and `nodeDescription` never written by any production caller at all. This is the
/// explicit pass that closes that gap, and the ONLY bulk writer — the launchd sync agent and the CLI
/// read translations and never write them.
///
/// Four of its five properties are scars from the eval run that already did this work once
/// (`measurements/2026-08-12-translation-ranking/README.md`):
///
/// - **Serial.** The generator that completed was serial; on-device throughput under concurrency is
///   unmeasured, and a bulk pass over someone's whole history is not where to find out.
/// - **Idempotent.** Check-then-skip against the content-keyed store, so a re-press pays only for
///   what is missing. The generator lacked this, died at 522/870, and had to be given it.
/// - **Resumable by construction.** Each `put` commits its own row, so a cancel, a crash or a quit
///   keeps every translation already made. There is no checkpoint to corrupt because there is none.
/// - **Cancellable.** Checked per unit; partial work stands.
/// - **Never throws, and never retries a nil.** An absent pack nils every call; retrying inside one
///   run cannot change that, and a later run genuinely might.
public enum TranslationBackfill {
  /// - Returns: the number of translations newly written, so the caller knows whether a reindex is
  ///   even warranted.
  public static func run(units: [TranslatableUnit], store: TranslationStore,
                         translator: any Translator, language: String,
                         progress: @Sendable (Int, Int) -> Void) async -> Int {
    guard !language.isEmpty else { return 0 }
    // Without this, an unopenable cache still runs every translator call (each `translation` lookup
    // and `put` write silently no-ops on a nil database) — 1,294 calls spent to write nothing, with
    // the progress bar and the caller both reporting success.
    guard store.isAvailable else { return 0 }
    let total = units.count
    var written = 0
    for (index, unit) in units.enumerated() {
      // Checked BEFORE the work, not after: cancelling must stop the next model call, and the unit
      // already in flight is allowed to finish and be stored rather than thrown away.
      if Task.isCancelled { return written }
      if store.translation(field: unit.field, sourceText: unit.sourceText, language: language) == nil,
         let text = await translator.translate(unit.sourceText,
                                               from: TranslationTarget.sourceLanguage, to: language) {
        store.put(field: unit.field, sourceText: unit.sourceText, language: language, text: text)
        written += 1
      }
      progress(index + 1, total)
    }
    return written
  }
}
