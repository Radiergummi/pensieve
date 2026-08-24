import Foundation
import PensieveKit

/// The CLI's narration wiring, in one place.
///
/// `prime` and `mcp` both hand `SessionContextQueries.bundle` a provider kind and a narration cache,
/// and each spelled the same three-line setup out itself — including *which* `PensievePaths` URL the
/// cache lives at, which is precisely the kind of fact that drifts when only one of the two is
/// edited. (It already has: the narratable event window used to differ between them, which made
/// every cache lookup a permanent miss.)
///
/// `narrating: false` is cache-READ-ONLY — a nil `summaryBuilder` never narrates, never spawns a
/// model and never blocks. That is the `prime` SessionStart hook's contract.
func cliNarrationOptions(narrating: Bool) -> NarrationOptions {
  let defaults = PensieveDefaults.shared()
  let builder = narrating ? SummaryBuilder(provider: makeDefaultLLMProvider(defaults: defaults)) : nil
  return NarrationOptions(
    summaryBuilder: builder,
    providerKind: resolvedProviderKind(defaults: defaults, cloudConfig: nil, apiKey: nil),
    cache: NarrationCache(url: PensievePaths.narrationCacheURL()))
}
