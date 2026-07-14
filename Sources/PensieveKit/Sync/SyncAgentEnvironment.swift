import Foundation

/// Runtime environment for the bundled sync agent. launchd REPLACES the job PATH (no login-PATH
/// inheritance), and a committed static plist cannot carry a home-relative PATH — so the helper
/// sets this at launch. `/usr/bin`+`/bin` are mandatory for `Git.run`'s `/usr/bin/env git`;
/// `~/.local/bin` (expanded) + `/opt/homebrew/bin` resolve `claude` for the extraction fallback.
public enum SyncAgentEnvironment {
  public static func resolvedPATH(home: URL) -> String {
    "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
  }
}
