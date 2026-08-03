import ArgumentParser
import Foundation
import PensieveKit

struct Scan: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "scan",
    abstract: "Discover sources (git repos) under a folder; --accept registers + installs hooks.")

  @Argument(help: "Folder to scan.") var folder: String
  @Flag(name: .long, help: "Recurse into subdirectories (default: folder + immediate children).") var recursive = false
  @Flag(name: .long, help: "Register discovered sources and install their capture setup.") var accept = false

  func run() throws {
    let database = try openCanonical()
    let pensievePath = PensievePaths.installedBinaryURL().path
    let scanner = SourceScanner(types: [GitSource(pensievePath: pensievePath)])
    let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).resolvingSymlinksInPath()

    let candidates = try scanner.discover(root: root, recursive: recursive, database: database)
    guard !candidates.isEmpty else { print("no sources found under \(root.path)"); return }

    if !accept {
      print("discovered \(candidates.count) source(s):")
      for candidate in candidates {
        let registeredSuffix = candidate.alreadyRegistered ? "  [registered]" : ""
        print("  \(candidate.source.kind)  \(candidate.source.displayName)  \(candidate.source.directory.path)\(registeredSuffix)")
      }
      print("\nre-run with --accept to register + install hooks.")
      return
    }

    let fresh = candidates.filter { !$0.alreadyRegistered }.map(\.source)
    let result = try scanner.accept(fresh, database: database)
    let already = candidates.count - fresh.count
    print("registered \(result.registered.count), already \(already), setup-failed \(result.setupFailed.count)")
    for (source, why) in result.setupFailed { print("  ! \(source.displayName): \(why)") }
  }
}
