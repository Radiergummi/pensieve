import Testing
import Foundation
@testable import PensieveKit

@Test func plistHasStablePathAbsolutePATHAndBackgroundType() throws {
  let home = URL(fileURLWithPath: "/Users/tester")
  let d = LaunchAgentPlist.dictionary(pensievePath: "/Users/tester/.local/bin/pensieve", home: home)

  #expect(d["Label"] as? String == "com.pensieve.sync")
  #expect(d["ProgramArguments"] as? [String] == ["/Users/tester/.local/bin/pensieve", "sync"])
  #expect(d["StartInterval"] as? Int == 300)
  #expect(d["RunAtLoad"] as? Bool == true)
  #expect(d["ProcessType"] as? String == "Background")
  #expect(d["StandardOutPath"] as? String == "/Users/tester/Library/Logs/Pensieve/sync.log")

  let path = (d["EnvironmentVariables"] as? [String: String])?["PATH"] ?? ""
  #expect(!path.contains("~"))                                   // launchd does not expand ~
  #expect(path.contains("/usr/bin"))                             // Git.run needs /usr/bin/env git
  #expect(path.contains("/Users/tester/.local/bin"))            // claude -p fallback
  #expect(path.contains("/opt/homebrew/bin"))
}

@Test func plistDataRoundTripsAsXML() throws {
  let home = URL(fileURLWithPath: "/Users/tester")
  let data = try LaunchAgentPlist.data(pensievePath: "/Users/tester/.local/bin/pensieve", home: home)
  let obj = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
  #expect(obj["Label"] as? String == "com.pensieve.sync")
}
