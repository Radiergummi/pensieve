import Testing
import Foundation
@testable import PensieveKit

/// `shared()` must always hand back a usable, non-nil `UserDefaults`, and a value written through
/// it must read back through it — otherwise a relocation written by one process (the app) could
/// become invisible to another (the CLI/daemon) reading the same domain.
///
/// Under `swift test` the running process's bundle identifier is not `PensieveDefaults.appDomain`,
/// so this exercises the suite-instance branch. The `.standard` branch (a process whose own bundle
/// identifier IS the app domain) is only reachable inside the built app and is covered by the app
/// build, not this suite.
@Test func sharedDefaultsRoundTripsAWrittenValue() {
  let defaults = PensieveDefaults.shared()

  let key = "sharedDefaultsRoundTripsAWrittenValueTestKey"
  defer { defaults.removeObject(forKey: key) }

  defaults.set("/Volumes/Work/Pensieve", forKey: key)
  #expect(defaults.string(forKey: key) == "/Volumes/Work/Pensieve")
}
