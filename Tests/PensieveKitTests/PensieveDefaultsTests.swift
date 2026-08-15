import Testing
import Foundation
@testable import PensieveKit

/// `shared()` must always hand back a usable, non-nil `UserDefaults`, and a value written through
/// it must read back through it — otherwise a relocation written by one process (the app) could
/// become invisible to another (the CLI/daemon) reading the same domain.
///
/// This exercises the suite-instance branch via the injected identifier (never the real
/// `Bundle.main.bundleIdentifier`, which under `swift test` is never `appDomain` anyway — see
/// `sharedReturnsStandardForItsOwnDomain` / `sharedReturnsTheSuiteForADifferentDomain` below for
/// the branch itself).
@Test func sharedDefaultsRoundTripsAWrittenValue() {
  let defaults = PensieveDefaults.shared(bundleIdentifier: "me.mazetti.pensieve.cli")

  let key = "sharedDefaultsRoundTripsAWrittenValueTestKey"
  defer { defaults.removeObject(forKey: key) }

  defaults.set("/Volumes/Work/Pensieve", forKey: key)
  #expect(defaults.string(forKey: key) == "/Volumes/Work/Pensieve")
}

/// The R1 guard itself: a process reading ITS OWN defaults domain (bundle identifier == appDomain)
/// must get `.standard`, by IDENTITY — `UserDefaults(suiteName: appDomain)` would construct an
/// equally "usable" but distinct instance, so `==` can't tell the two apart; only `===` proves the
/// guard actually short-circuited to the singleton rather than merely returning something that reads
/// the same values.
@Test func sharedReturnsStandardForItsOwnDomain() {
  #expect(PensieveDefaults.shared(bundleIdentifier: PensieveDefaults.appDomain) === UserDefaults.standard)
}

/// A different (or absent) bundle identifier — the CLI, the launchd helper, or `swift test` itself —
/// must NOT take the `.standard` shortcut, or a relocation the app writes to the suite domain would
/// read back from the wrong domain in every other process.
@Test func sharedReturnsTheSuiteForADifferentDomain() {
  #expect(PensieveDefaults.shared(bundleIdentifier: "me.mazetti.pensieve.cli") !== UserDefaults.standard)
  #expect(PensieveDefaults.shared(bundleIdentifier: nil) !== UserDefaults.standard)
}
