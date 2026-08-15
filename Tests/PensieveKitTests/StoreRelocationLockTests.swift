import Testing
import Foundation
@testable import PensieveKit

/// A per-test anchor. The real anchor is `~/Library/Caches/…`, which the test suite must never
/// touch — a test that locked it would block the developer's own running app.
private func temporaryAnchor() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("relocation-\(UUID().uuidString).lock")
}

@Test func exclusiveLockExcludesSharedAndExclusive() throws {
  let anchor = temporaryAnchor()
  defer { try? FileManager.default.removeItem(at: anchor) }

  let exclusive = StoreRelocationLock(at: anchor, exclusive: true)
  #expect(exclusive != nil)

  // While the relocator holds it, no writer may open and no second relocation may start.
  #expect(StoreRelocationLock(at: anchor, exclusive: false) == nil)
  #expect(StoreRelocationLock(at: anchor, exclusive: true) == nil)
}

@Test func sharedLocksCoexistButBlockExclusive() throws {
  let anchor = temporaryAnchor()
  defer { try? FileManager.default.removeItem(at: anchor) }

  // Two writers may run concurrently — that is today's behaviour and this must not change it.
  let firstWriter = StoreRelocationLock(at: anchor, exclusive: false)
  let secondWriter = StoreRelocationLock(at: anchor, exclusive: false)
  #expect(firstWriter != nil)
  #expect(secondWriter != nil)

  // But a relocation cannot begin under them.
  #expect(StoreRelocationLock(at: anchor, exclusive: true) == nil)
}

/// The lock must not wedge the system when its holder goes away. `flock` is released by the
/// kernel when the descriptor closes, including on crash — this asserts we did not defeat that
/// by leaking the descriptor somewhere it outlives the object.
@Test func releasingTheLockAllowsTheNextAcquisition() throws {
  let anchor = temporaryAnchor()
  defer { try? FileManager.default.removeItem(at: anchor) }

  do {
    let held = StoreRelocationLock(at: anchor, exclusive: true)
    #expect(held != nil)
  }   // deinit here

  #expect(StoreRelocationLock(at: anchor, exclusive: true) != nil)
}

/// The anchor is deliberately NOT inside the support directory. flock binds to an inode, so a
/// cross-volume copy would hand the writer a different inode of an identically-named file and the
/// guard would evaporate in exactly the case it exists for.
@Test func anchorIsOutsideTheSupportDirectory() {
  let anchor = StoreRelocationLock.anchorURL().path
  #expect(!anchor.hasPrefix(PensievePaths.defaultSupportDirectory().path))
  #expect(anchor.hasSuffix("/Library/Caches/me.mazetti.pensieve/relocation.lock"))
}
