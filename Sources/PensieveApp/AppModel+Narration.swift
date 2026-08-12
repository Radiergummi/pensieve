// Sources/PensieveApp/AppModel+Narration.swift
import Foundation
import PensieveKit

extension AppModel {
  /// Reads the app-side cloud inputs: config from UserDefaults (via the tested Kit derivation, which
  /// defaults an unset flavor to the one the picker shows), key from the Keychain. The config is
  /// always non-nil — "not configured" is expressed by `isUsable` / a missing key, not by nil.
  func cloudInputs() -> (CloudConfig?, String?) {
    let config = CloudConfig.fromDefaults(.standard)
    let key = KeychainSecretStore().read(
      account: CloudPresets.keychainAccount(flavor: config.flavor, baseURL: config.baseURL))
    return (config, key)
  }

  /// Rebuild the narration provider + its cache kind from the current UserDefaults selection + cloud
  /// inputs. The kind folds flavor+model in ONLY when the resolved kind is actually "cloud", so a
  /// not-configured cloud selection keys as the real local kind that runs.
  func rebuildSummaryBuilder() {
    let (config, key) = cloudInputs()
    let provider = makeDefaultLLMProvider(cloudConfig: config, apiKey: key)
    summaryBuilder = SummaryBuilder(provider: provider)
    descriptionProvider = provider
    let kind = resolvedProviderKind(cloudConfig: config, apiKey: key)
    if kind == "cloud", let config {
      let account = CloudPresets.keychainAccount(flavor: config.flavor, baseURL: config.baseURL)
      providerKind = "cloud:\(account):\(config.model)"
    } else {
      providerKind = kind
    }
    AppLog.app.info("Provider rebuilt: \(self.providerKind, privacy: .public)")
  }

  static func narrationCacheDefaultsKey() -> String {
    "pensieve.narrationCache." + Stores.canonicalURL.path
  }
  func loadNarrationCache() {
    guard let data = UserDefaults.standard.data(forKey: Self.narrationCacheDefaultsKey()),
          let decoded = try? JSONDecoder().decode([UUID: CachedNarration].self, from: data)
    else { return }
    narrationCache = decoded
  }
  func saveNarrationCache() {
    guard let data = try? JSONEncoder().encode(narrationCache) else { return }
    UserDefaults.standard.set(data, forKey: Self.narrationCacheDefaultsKey())
  }
  /// Drop entries for nodes that no longer exist (deleted / merged away) so the plist can't grow
  /// unbounded. Keyed directly by node id, so intersecting with the live set is the whole fix.
  func pruneNarrationCache() {
    let live = Set(allNodes.map(\.id))
    let before = narrationCache.count
    narrationCache = narrationCache.filter { live.contains($0.key) }
    if narrationCache.count != before { saveNarrationCache() }
  }

  /// Cached narration for `node` IFF the stored key still matches the current events. Synchronous —
  /// lets the view render a valid cached recap instantly (including across launches).
  func cachedNarration(for node: Node, events: [Event]) -> String? {
    guard let entry = narrationCache[node.id],
          entry.key == NarrationCacheKey.make(events: events, provider: providerKind) else { return nil }
    return entry.prose
  }

  /// The "Last Work Done" narration for `node`. Returns the cached result when its key matches and
  /// `force` is false; otherwise regenerates off-main, stores prose+key, and returns it. `force`
  /// (⌘R on the selected node) bypasses the cache so the user can always refresh a bad recap.
  func narration(for node: Node, events: [Event], force: Bool = false) async -> String? {
    let key = NarrationCacheKey.make(events: events, provider: providerKind)
    if !force, let entry = narrationCache[node.id], entry.key == key { return entry.prose }
    let text = await summaryBuilder.narrate(project: node, events: events)
    if let text {
      narrationCache[node.id] = CachedNarration(prose: text, key: key)
      saveNarrationCache()
    }
    return text
  }

  /// True when `node` is a project with exactly one git source — i.e. `NodeDescriber` can act on
  /// it. Gates the DetailView's describe/refresh button so it never appears where it would no-op.
  func isDescribable(_ node: Node) -> Bool {
    guard node.kind == .project, let database else { return false }
    let key = try? database.read { database in try NodeDescriber.soleGitRepoKey(database, nodeID: node.id) }
    return (key ?? nil) != nil
  }

  /// Manual "describe this node" action: force-derive `node`'s description off-main via the retained
  /// provider, then refresh so the new text renders. Best-effort — a failure/empty leaves the
  /// existing description untouched. Returns the outcome so the view can show an inline note.
  func describeNode(_ node: Node) async -> NodeDescriber.Outcome {
    guard let database else { return .ineligible }
    let outcome = await NodeDescriber.describe(database, nodeID: node.id, provider: descriptionProvider, force: true)
    refresh()
    return outcome
  }

  /// The narration as it should RENDER: the English prose when translation is off, its STORED
  /// translation when a target is set, and `nil` when a target is set but this prose has not been
  /// translated yet.
  ///
  /// That nil is deliberate and load-bearing. Returning the English fallback here would satisfy
  /// `DetailView`'s `if let cached` fast path, which returns early — so the async `displayNarration`,
  /// the only path that calls the translator and writes to the store, would never run. Since
  /// `NarrationCacheKey` folds in events and provider but NOT language, every node narrated before
  /// the user enabled a target would render English forever, self-healing only on a manual ⌘R.
  /// Returning nil costs one spinner per node on first open after enabling, then never again.
  func cachedDisplayNarration(for node: Node, events: [Event]) -> String? {
    guard let prose = cachedNarration(for: node, events: events) else { return nil }
    let language = TranslationTarget.resolved()
    guard !language.isEmpty else { return prose }
    return translationStore.translation(field: .narration, sourceText: prose, language: language)
  }

  /// Generate (or reuse) the narration, then resolve its display form — translating and storing it if
  /// this is the first time this prose has been seen in the target language.
  ///
  /// Translation happens BEFORE the view first renders the prose, giving one atomic spinner → German
  /// transition. An English→German flicker would be worse, and would add a second stale-render window
  /// to a state machine that needed two adversarial reviews plus an Opus review to get right.
  func displayNarration(for node: Node, events: [Event], force: Bool = false) async -> String? {
    guard let prose = await narration(for: node, events: events, force: force) else { return nil }
    let language = TranslationTarget.resolved()
    guard !language.isEmpty else { return prose }
    if let stored = translationStore.translation(field: .narration, sourceText: prose,
                                                 language: language) { return stored }
    guard let translator,
          let translated = await translator.translate(prose,
                                                      from: TranslationTarget.sourceLanguage,
                                                      to: language)
    else { return prose }   // best-effort: the English original is always an acceptable answer
    translationStore.put(field: .narration, sourceText: prose, language: language, text: translated)
    return translated
  }
}
