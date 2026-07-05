import ArgumentParser
import Foundation
import PensieveKit

struct InstallDaemon: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "install-daemon",
    abstract: "Install (or --uninstall) the launchd agent that runs `pensieve sync` every 5 min.")

  @Flag(name: .long, help: "Remove the daemon instead of installing it.")
  var uninstall = false

  func run() throws {
    let home = PensievePaths.homeDirectory()
    let plistURL = PensievePaths.launchAgentURL()
    let uid = String(getuid())

    if uninstall {
      DaemonInstaller.unload(plistURL: plistURL, uid: uid)
      print("uninstalled daemon (\(plistURL.path))")
      return
    }

    let running = Bundle.main.executablePath ?? ""
    try DaemonInstaller.writePlist(home: home, runningExecutable: running, plistURL: plistURL)
    DaemonInstaller.load(plistURL: plistURL, uid: uid)
    print("installed daemon: runs `\(DaemonInstaller.stablePensievePath(home: home)) sync` every 5 min")
  }
}
