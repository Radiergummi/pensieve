import SwiftUI
// Load-bearing and FILE-SCOPED: `@preconcurrency` suppresses this file's Sendable warnings from the
// `Translation` framework's un-audited types (`LanguageAvailability`, the `.translationTask` below).
@preconcurrency import Translation
import PensieveKit

/// One offered target language.
struct TranslationLanguageOption: Identifiable, Hashable {
  /// `Locale.Language.minimalIdentifier`, and the value persisted to UserDefaults.
  ///
  /// Probed against this Mac's 29 offered targets: every minimal identifier round-trips through
  /// `Locale.Language(identifier:)` unchanged, and the framework reports script/region variants as
  /// distinct entries (`zh` = zh-Hans-CN, `zh-HK` = zh-Hant-HK, `pt` = pt-Latn-BR, `pt-PT`). So the
  /// minimal form loses nothing, whereas `maximalIdentifier` would store `zh-Hans-CN` for a user who
  /// chose `zh`, and a bare language code would collapse `zh-HK` onto `zh` — the wrong script.
  let code: String
  let name: String
  let isInstalled: Bool
  var id: String { code }
}

/// What this Mac can translate English into.
///
/// `LanguageAvailability` is macOS 15+ (only `TranslationSession(installedSource:)` is 26+), and the
/// app's deployment target is 26.0 — well past that floor — so this needs no availability annotation.
/// Measured on this machine: 38 supported languages, of which 9 are English variants reporting
/// `.unsupported` (en→en) and drop out by that status alone — no hand-maintained exclusion list.
enum TranslationLanguageCatalog {
  /// Concurrent, and the ordering objection does not apply: the results are re-sorted by name below,
  /// so collection order cannot affect what this returns. Measured on this machine — `supportedLanguages`
  /// 9.7 ms, then 38 serial `status(from:to:)` probes 184 ms (~4.8 ms each, warm) versus 82 ms through
  /// a task group. This runs on every Settings open, and the picker shows only "Off" until it lands.
  static func load() async -> [TranslationLanguageOption] {
    let availability = LanguageAvailability()
    let english = Locale.Language(identifier: TranslationTarget.sourceLanguage)
    let options = await withTaskGroup(of: TranslationLanguageOption?.self) { group in
      for language in await availability.supportedLanguages {
        group.addTask {
          let status = await availability.status(from: english, to: language)
          guard status != .unsupported else { return nil }
          let code = language.minimalIdentifier
          return TranslationLanguageOption(code: code,
                                           name: TranslationTarget.displayName(for: code),
                                           isInstalled: status == .installed)
        }
      }
      return await group.reduce(into: [TranslationLanguageOption]()) { found, option in
        if let option { found.append(option) }
      }
    }
    return options.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}

/// Settings ▸ Intelligence ▸ Translation. The target picker, language-pack status with a download
/// affordance, a link to the OS pane that owns pack lifecycle, and the coverage/backfill row.
///
/// Extracted from `IntelligenceSettingsTab` rather than grown inside it: CI runs `swiftlint --strict`
/// with a 400-line cap and that file was already over half of it.
struct TranslationSettingsSection: View {
  var model: AppModel
  @AppStorage(PensieveDefaults.translationTargetKey) private var translationTarget = TranslationTarget.off

  /// The single source of truth for "is this pack installed" — the picker's `⤓` marker, the status
  /// line and the backfill button's enablement all read it. It previously ALSO lived in a separate
  /// `@State isInstalled` refreshed on its own schedule, and because `options` was loaded once and
  /// never reloaded, a completed download flipped the status line to "Ready to translate" while the
  /// picker row directly above still carried `⤓`. One representation, reloaded after a download.
  @State private var options: [TranslationLanguageOption] = []
  /// The language a Download tap actually captured, or nil while nothing is in flight. Compared
  /// synchronously against `translationTarget` (not reset from inside the async download closure) so
  /// switching the picker mid-download can never mount a `.translationTask` for the newly selected
  /// language — see `packStatus` below.
  @State private var downloadingLanguage: String?
  /// Whether this window is the one the user is looking at. Watched, not merely read — see the
  /// `.onChange` below.
  @Environment(\.controlActiveState) private var controlActiveState

  private var isOff: Bool { translationTarget == TranslationTarget.off }
  private var isInstalled: Bool {
    options.first { $0.code == translationTarget }?.isInstalled ?? false
  }

  var body: some View {
    Picker("Translate generated text to", selection: $translationTarget) {
      Text("Off").tag(TranslationTarget.off)
      ForEach(options) { option in
        // Content, not chrome: a language's own name is never a catalog key.
        Text(verbatim: option.isInstalled ? option.name : "\(option.name) ⤓").tag(option.code)
      }
      // A persisted target the framework no longer reports still shows as selected rather than
      // blanking the picker.
      if !isOff, !options.contains(where: { $0.code == translationTarget }) {
        Text(verbatim: TranslationTarget.displayName(for: translationTarget)).tag(translationTarget)
      }
    }
    .task { options = await TranslationLanguageCatalog.load() }
    .task(id: translationTarget) { await model.measureTranslationCoverage() }
    // NOT `.task(id:)`: a `.task(id:)` body also runs on first appear, which would cancel a run in
    // flight every time Settings merely reopens — and "closing Settings does not kill a run, and
    // reopening shows it still going" is this feature's whole point. `.onChange` fires only on an
    // actual change, so a language switch cancels a stale run without touching one just opened into.
    .onChange(of: translationTarget) { _, _ in
      model.cancelTranslationBackfill()
      // Synchronous with the picker write, which is the whole point — see `downloadingLanguage`.
      downloadingLanguage = nil
    }
    // The "Manage installed languages in System Settings…" button below sends the user OUT to install
    // a pack while this window stays open, and `options` was loaded exactly once. On return the picker
    // still showed `⤓`, the status line still read "isn't downloaded yet", and — since `isInstalled`
    // derives from `options` — "Translate remaining" stayed disabled for a pack that was in fact
    // installed, recoverable only by closing and reopening Settings. Re-probing when this window
    // becomes key again is the narrowest signal that covers it, and it catches a pack DELETED out
    // there just as well. Cheap enough to run on a window focus: measured 82 ms through the task group.
    .onChange(of: controlActiveState) { _, state in
      guard state == .key else { return }
      Task { options = await TranslationLanguageCatalog.load() }
    }

    if !isOff {
      if #available(macOS 26, *) {
        packStatus
        coverageRow
      } else {
        Text("Translation requires macOS 26 or later.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Button("Manage installed languages in System Settings…") {
        // Verified present on macOS 26: this extension owns the "Translation Languages" UI. Deleting
        // a pack is OS-only, so linking out is the honest ceiling of "manage".
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
          NSWorkspace.shared.open(url)
        }
      }
      .buttonStyle(.link)
      .font(.caption)
    }
  }

  @available(macOS 26, *)
  @ViewBuilder private var packStatus: some View {
    HStack {
      // The ONLY view-attached translation in the app, and it is attached only while a download the
      // user actually asked for is running. Previously `.translationTask` was gated on the plain
      // `Bool` `isDownloading`, reset only from inside its own async completion closure — a mid-
      // download picker switch renders before that closure resumes, so the stale-`true` flag mounted a
      // NEW `.translationTask` for the newly selected language, one the user never clicked Download
      // for. Gating on `downloadingLanguage == translationTarget` instead makes the guard synchronous
      // with the picker write: the render that follows a switch evaluates unequal and mounts nothing,
      // with no async closure needing to "catch up" first.
      if let downloadingLanguage, downloadingLanguage == translationTarget {
        // A headless `TranslationSession(installedSource:)` cannot request a download
        // (`canRequestDownloads`), which is why first-run acquisition has to happen in a view.
        ProgressView().controlSize(.small)
        Text("Preparing the language…")
          .font(.caption).foregroundStyle(.secondary)
          .translationTask(source: Locale.Language(identifier: TranslationTarget.sourceLanguage),
                           target: Locale.Language(identifier: downloadingLanguage)) { session in
            try? await session.prepareTranslation()
            // Cancellation is cooperative: `prepareTranslation()` may resume after the user has
            // already switched languages. Only the closure whose captured language still matches the
            // live selection may write outcome state — a superseded closure writes nothing.
            guard downloadingLanguage == translationTarget else { return }
            // Reloading the whole catalog rather than probing this one language keeps installed-status
            // in ONE place: the picker's `⤓` markers refresh with the status line instead of drifting.
            options = await TranslationLanguageCatalog.load()
            self.downloadingLanguage = nil
          }
      } else if isInstalled {
        Label("Ready to translate on this Mac.", systemImage: "checkmark.circle")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Label("This language isn’t downloaded yet.", systemImage: "arrow.down.circle")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Download…") { downloadingLanguage = translationTarget }
      }
    }
  }

  /// Coverage plus the one button that starts or stops the bulk pass. Disabled when the pack is not
  /// installed: 1,294 calls that each nil out is not a run worth starting, and the Download button
  /// directly above is the actual next step.
  ///
  /// The stored coverage is shown only when it was measured FOR the currently selected language:
  /// `translationCoverage.language == translationTarget`. A re-measure after a language switch takes
  /// a full corpus gather, and during that window the row shows nothing rather than the previous
  /// language's numbers under the new selection — a mismatch, not a stale display, is the honest
  /// state to render.
  ///
  /// "Translated" during the progress bar would overstate what happened: `TranslationBackfill`
  /// advances its counter on every unit it ATTEMPTS, not every one it writes (a missing language pack
  /// mid-run nils out every call while the counter still climbs to the total). "Translating N of M…"
  /// is honest in that degraded path and leaves the coverage row's own "translated" meaning only what
  /// it actually measured from the store.
  ///
  /// The progress branch carries the same language gate as the coverage branch, for the same reason:
  /// cancellation is cooperative, so a run cancelled by a language switch keeps existing until its
  /// in-flight unit returns, and rendering its counter under the new selection would attribute that
  /// work to the wrong target. Showing nothing during that window is the honest state.
  @available(macOS 26, *)
  @ViewBuilder private var coverageRow: some View {
    if let run = model.translationBackfillRun, run.language == translationTarget {
      VStack(alignment: .leading, spacing: 4) {
        ProgressView(value: Double(run.done), total: Double(max(run.total, 1)))
        HStack {
          Text("Translating \(run.done) of \(run.total)…")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Stop") { model.cancelTranslationBackfill() }
        }
      }
    } else if let coverage = model.translationCoverage, coverage.language == translationTarget {
      HStack {
        Text("\(coverage.translated) of \(coverage.total) translated")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        // Nothing missing: the count already says so. A second sentence beside it would stutter.
        if !coverage.missing.isEmpty {
          // The run check is not redundant with the branch above: a run cancelled by a language
          // switch survives its in-flight unit, so this branch can be the one rendering while
          // `startTranslationBackfill`'s own `translationBackfillRun == nil` guard would still refuse.
          // A button that silently does nothing is worse than one that says it cannot yet.
          Button("Translate remaining") { model.startTranslationBackfill() }
            .disabled(!isInstalled || model.translationBackfillRun != nil)
        }
      }
    }
  }
}
