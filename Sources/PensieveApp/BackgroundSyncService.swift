import ServiceManagement

/// Thin wrapper over the bundled SMAppService LaunchAgent. Smoke-verified by hand (SMAppService
/// mutates live system state); the scheduled logic (SyncRunner) is tested in PensieveKit. Uses the
/// app target's own `AppLog.app` logger — PensieveKit's `Log` enum is internal to the framework.
enum BackgroundSyncService {
  static let plistName = "me.mazetti.pensieve.sync.plist"
  static var agent: SMAppService { SMAppService.agent(plistName: plistName) }
  static var status: SMAppService.Status { agent.status }

  /// Register (and refresh) the bundled agent. Called on every launch when the preference is on,
  /// and by the Settings toggle when switched on.
  ///
  /// This unregisters first, then registers — NOT a bare `register()` — because the app is ad-hoc
  /// signed and rebuilt often. Each rebuild mints a new helper cdhash, and SMAppService pins the
  /// launchd registration to path + cdhash via a LightWeight Code Requirement (LWCR). The spike
  /// confirmed that a bare `register()` on an already-`.enabled` item is a silent no-op that does
  /// NOT refresh a stale LWCR, so a registration from a previous build keeps spawn-failing
  /// (`EX_CONFIG` / "Launch Constraint Violation" kills) on every interval. `unregister()` +
  /// `register()` rebuilds the LWCR against the current binary. Approval PERSISTS across this cycle
  /// for an already-approved bundle id (spike-verified: no re-prompt), so this costs nothing on a
  /// normal launch — it only heals the cdhash after a rebuild.
  ///
  /// The unregister MUST be awaited (the async API): BTM drops the record asynchronously, and a
  /// synchronous unregister immediately followed by `register()` races — the re-register can land
  /// before the old record is gone, silently keeping the stale LWCR (observed live: the helper
  /// kept dying with "Launch Constraint Violation" across relaunches until the await was added).
  static func registerIfNeeded() {
    Task.detached {
      try? await agent.unregister()   // throws when nothing is registered — fine, ignore
      do { try agent.register() } catch { AppLog.app.error("SMAppService register failed: \(error, privacy: .public)") }
    }
  }

  static func unregister() {
    do { try agent.unregister() } catch { AppLog.app.error("SMAppService unregister failed: \(error, privacy: .public)") }
  }
}
