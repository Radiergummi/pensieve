/// Refuse to register/boot the background agent when the app runs from a `.build` path (a throwaway
/// xcodebuild smoke-launch), which would otherwise pollute real Login Items and tear down the live
/// agent. Mirrors the retired DaemonInstaller.ensureStable "refuse from /.build/" rule.
public enum BackgroundSyncGuard {
  public static func shouldManage(bundlePath: String) -> Bool {
    !bundlePath.contains("/.build")
  }
}
