import Foundation
import CryptoKit

/// The ONE place source-specifics live for idempotency. Each kind maps its payload to a
/// stable string; the ingester dedups generically on (sourceID, fingerprint).
public enum Fingerprint {
  public static func commit(hash: String) -> String { "commit:\(hash)" }

  public static func session(sessionID: String, contents: String) -> String {
    "session:\(sessionID):\(sha1(contents))"
  }

  /// Checkouts have no natural immutable id; synthesize one (identical toggles may collapse).
  public static func checkout(repo: String, from: String, to: String, branch: String) -> String {
    "checkout:\(sha1("\(repo)|\(from)|\(to)|\(branch)"))"
  }

  private static func sha1(_ s: String) -> String {
    Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
