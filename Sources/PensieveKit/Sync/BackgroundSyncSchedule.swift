import Foundation

/// The one statement of how often background sync runs, and everything derived from it.
///
/// The period lives in a **static plist** (`SyncAgent/me.mazetti.pensieve.sync.plist`), which cannot
/// reference Swift, so this constant and that file must agree by convention. The enforcement point is
/// therefore a test: `committedAgentPlistIsHomeIndependentAndComplete` asserts `StartInterval`
/// against `interval` here. Two things previously restated the period on their own —
/// `WidgetDigest.stalenessThreshold` hardcoded `20 * 60` with a comment explaining it as "four missed
/// 300 s passes", and the plist test hardcoded `300` — so changing the schedule would have left the
/// widget calling a fresh digest stale (or a stale one fresh) with nothing failing.
public enum BackgroundSyncSchedule {
  /// `StartInterval` in the agent plist. Keep the two in sync; the plist test fails if they drift.
  public static let interval: TimeInterval = 300

  /// How many consecutive missed passes before the widget calls its digest stale. Comfortably past
  /// normal launchd jitter, short enough that a real outage is visible.
  public static let missedPassesBeforeStale = 4

  /// The agent's own wall-clock watchdog for a single pass.
  ///
  /// This exists because launchd will **not** start a second instance of the agent while one is
  /// running, so a pass that hangs does not merely fail — it silently stops all background
  /// ingestion until logout, with a clean log and a frozen `sync.log` mtime that Settings ▸ Advanced
  /// renders as an ordinary "Last sync: 2 days ago", indistinguishable from "never registered".
  ///
  /// Deliberately generous rather than tight: this is a watchdog for a hang, not a scheduler. A pass
  /// legitimately makes many model calls, and aborting a slow-but-progressing pass would starve
  /// extraction — which is incremental, so an aborted pass loses only the session it was on (the
  /// watermark is not advanced, so it retries). Three missed intervals is unambiguously a hang.
  public static let passWatchdog: TimeInterval = interval * 3
}
