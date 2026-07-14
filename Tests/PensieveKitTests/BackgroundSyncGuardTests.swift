import Testing
@testable import PensieveKit

@Test func guardRefusesBuildPathsAndAllowsInstalled() {
  #expect(BackgroundSyncGuard.shouldManage(bundlePath: "/Applications/Pensieve.app") == true)
  #expect(BackgroundSyncGuard.shouldManage(
    bundlePath: "/Users/x/Projects/pensieve/.build-xcode/Build/Products/Debug/Pensieve.app") == false)
  #expect(BackgroundSyncGuard.shouldManage(bundlePath: "/repo/.build/debug/Pensieve.app") == false)
}
