import ServiceManagement

/// Thin wrapper over the bundled SMAppService LaunchAgent. Smoke-verified by hand (SMAppService
/// mutates live system state); the scheduled logic (SyncRunner) is tested in PensieveKit. Uses the
/// app target's own `AppLog.app` logger — PensieveKit's `Log` enum is internal to the framework.
enum BackgroundSyncService {
  static let plistName = "me.mazetti.pensieve.sync.plist"
  static var agent: SMAppService { SMAppService.agent(plistName: plistName) }
  static var status: SMAppService.Status { agent.status }

  /// Status-gated register: only from `.notRegistered`, and never re-enable a user-disabled item.
  static func registerIfNeeded() {
    guard agent.status == .notRegistered else { return }
    do { try agent.register() }
    catch { AppLog.app.error("SMAppService register failed: \(error, privacy: .public)") }
  }

  static func unregister() {
    do { try agent.unregister() }
    catch { AppLog.app.error("SMAppService unregister failed: \(error, privacy: .public)") }
  }
}
