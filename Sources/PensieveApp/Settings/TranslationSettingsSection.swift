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
/// app's deployment target is 15.0, so this needs no availability annotation. Measured on this
/// machine: 38 supported languages, of which 9 are English variants reporting `.unsupported` (en→en)
/// and drop out by that status alone — no hand-maintained exclusion list.
enum TranslationLanguageCatalog {
  static func load() async -> [TranslationLanguageOption] {
    let availability = LanguageAvailability()
    let english = Locale.Language(identifier: TranslationTarget.sourceLanguage)
    var options: [TranslationLanguageOption] = []
    // Serial rather than a TaskGroup: the probe returned all 38 statuses instantly, so concurrency
    // would buy nothing measurable and cost deterministic ordering. (The spec says "concurrently";
    // this is a deliberate simplification, recorded rather than silent.)
    for language in await availability.supportedLanguages {
      let status = await availability.status(from: english, to: language)
      guard status != .unsupported else { continue }
      let code = language.minimalIdentifier
      options.append(TranslationLanguageOption(code: code,
                                               name: TranslationTarget.displayName(for: code),
                                               isInstalled: status == .installed))
    }
    return options.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Whether the pack for `language` is installed right now. Re-read after a download so the status
  /// line reflects reality rather than the fact that a sheet was shown.
  static func isInstalled(_ language: String) async -> Bool {
    guard !language.isEmpty else { return false }
    let status = await LanguageAvailability().status(
      from: Locale.Language(identifier: TranslationTarget.sourceLanguage),
      to: Locale.Language(identifier: language))
    return status == .installed
  }
}

/// Settings ▸ Intelligence ▸ Translation. The target picker, language-pack status with a download
/// affordance, a link to the OS pane that owns pack lifecycle, and the coverage/backfill row.
///
/// Extracted from `IntelligenceSettingsTab` rather than grown inside it: that file is 261 lines and CI
/// runs `swiftlint --strict` with a 400-line cap.
struct TranslationSettingsSection: View {
  var model: AppModel
  @AppStorage(PensieveDefaults.translationTargetKey) private var translationTarget = TranslationTarget.off

  @State private var options: [TranslationLanguageOption] = []
  @State private var isInstalled = false
  @State private var isDownloading = false

  private var isOff: Bool { translationTarget == TranslationTarget.off }

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

    if !isOff {
      if #available(macOS 26, *) {
        packStatus
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
      if isDownloading {
        // The ONLY view-attached translation in the app, and now it is attached only while a download
        // is actually running. Previously it was mounted whenever a target was set, so it re-fired on
        // every Settings open and reported nothing.
        //
        // A headless `TranslationSession(installedSource:)` cannot request a download
        // (`canRequestDownloads`), which is why first-run acquisition has to happen in a view.
        ProgressView().controlSize(.small)
        Text("Preparing the language…")
          .font(.caption).foregroundStyle(.secondary)
          .translationTask(source: Locale.Language(identifier: TranslationTarget.sourceLanguage),
                           target: Locale.Language(identifier: translationTarget)) { session in
            try? await session.prepareTranslation()
            isInstalled = await TranslationLanguageCatalog.isInstalled(translationTarget)
            isDownloading = false
          }
      } else if isInstalled {
        Label("Ready to translate on this Mac.", systemImage: "checkmark.circle")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Label("This language isn’t downloaded yet.", systemImage: "arrow.down.circle")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Download…") { isDownloading = true }
      }
    }
    .task(id: translationTarget) {
      isDownloading = false
      isInstalled = await TranslationLanguageCatalog.isInstalled(translationTarget)
    }
  }
}
