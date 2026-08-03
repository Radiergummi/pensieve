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
}
