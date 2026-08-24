import ArgumentParser
import Foundation
import PensieveKit

struct CaptureSessionEnd: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "capture-session-end",
    abstract: "Record a Claude Code transcript at session end (reads hook JSON from stdin).")

  func run() {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let ref = sessionRefFromSessionEndHook(data) else { return }  // dumb: never fail a session
    appendCapture(kind: CaptureKind.ccSession, encoding: ref)
  }
}
