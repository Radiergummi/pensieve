import Testing
import Foundation
@testable import PensieveKit

/// The App Group identifier exists in four places that cannot reference each other: once in Swift
/// (`PensievePaths.appGroupIdentifier`) and once in each of the three `.entitlements` files. A
/// `.entitlements` file is a plist consumed by the signing step, so there is no way to make it read
/// the Swift constant — which makes this test the only thing holding them together.
///
/// The failure it prevents is specifically nasty because it is **silent and one-sided**. Every
/// unsandboxed process in this project (the app, the CLI, the sync agent) falls back to constructing
/// `~/Library/Group Containers/<id>` directly and gets no entitlement check at all, so it keeps
/// working against whatever string Swift holds. Only the **sandboxed widget** must ask the system for
/// its container, and it asks using the *entitlement's* string. Change the identifier on one side and
/// the app happily publishes a digest to one path while the widget reads another — the widget renders
/// "Open Pensieve to get started" forever, with nothing logged as an error anywhere, because from each
/// side's own point of view nothing failed.
///
/// Reads the committed files rather than the built product deliberately: the point is to fail in
/// `make test` (and CI) the moment the two disagree, not after a build and an install.
@Test func everyEntitlementsFileDeclaresTheAppGroupSwiftUses() throws {
  // Tests/PensieveKitTests/<file> → repo root, the same walk `BackgroundSyncPlistTests` uses.
  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  // All three are asserted by name rather than discovered by globbing the directory: a glob would
  // silently pass if a target's entitlements file were renamed or deleted, which is one of the ways
  // the widget loses its container.
  let entitlementsFileNames = [
    "Pensieve.entitlements",           // the app: publishes the digest
    "PensieveWidget.entitlements",     // the widget: the ONLY reader that needs a real container
    "PensieveSyncAgent.entitlements",  // the agent: publishes with the app closed
  ]

  for fileName in entitlementsFileNames {
    let url = repositoryRoot.appendingPathComponent(fileName)
    let plist = try PropertyListSerialization.propertyList(
      from: try Data(contentsOf: url), format: nil) as? [String: Any]
    let groups = try #require(plist?["com.apple.security.application-groups"] as? [String],
                              "\(fileName) declares no application-groups array")
    #expect(groups.contains(PensievePaths.appGroupIdentifier),
            "\(fileName) declares \(groups), which does not include \(PensievePaths.appGroupIdentifier)")
  }

  // The `group.` prefix is load-bearing, not cosmetic: it is the only form Apple's Developer portal
  // accepts when registering an App Group, and that registration is what lets Xcode mint the
  // provisioning profile. Without a profile `secd` ignores the entitlement outright and the
  // sandboxed widget gets no container — the same silent failure, arriving through signing instead
  // of through a typo.
  #expect(PensievePaths.appGroupIdentifier.hasPrefix("group."))
}
