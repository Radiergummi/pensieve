import Foundation

/// Fallback provider: shells out to `claude -p` (subscription auth, no API key).
public struct ClaudeCLIProvider: LLMProvider {
  private let run: @Sendable (String) throws -> String
  public init(run: @escaping @Sendable (String) throws -> String = ClaudeCLIProvider.shellRun) {
    self.run = run
  }

  public func complete(prompt: String) async throws -> String {
    // The subprocess is blocking, so run it on a background queue rather than parking a
    // Swift-concurrency cooperative worker for the whole call. `shellRun` bounds a hung
    // `claude -p` with its own wall-clock timeout (so the awaiting Task can't hang forever).
    let run = self.run
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        do { continuation.resume(returning: try run(prompt)) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }

  /// Wall-clock cap on a single `claude -p` invocation. A hung child is terminated and the call
  /// throws rather than blocking a narration/extraction Task indefinitely.
  static let timeout: TimeInterval = 120

  /// Runs `claude -p` with the prompt on stdin; returns trimmed stdout.
  ///
  /// Resolves `claude` via `PATH` (`/usr/bin/env`). Interactive shells have it; a launchd context
  /// only does if the LaunchAgent injects a `PATH` covering the install dir — the CLI is the
  /// fallback provider (on-device Foundation Models is preferred when available), so this matters
  /// only on a machine without Foundation Models running under the daemon.
  public static func shellRun(_ prompt: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["claude", "-p"]
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    do { try process.run() } catch { throw LLMError.providerFailed("spawn: \(error)") }
    // Drain stdin/stdout/stderr concurrently to avoid deadlock: if any one of these pipes is
    // fully written/read before the others start, the child can block writing to a full pipe
    // buffer (e.g. large stderr diagnostics) while the parent is stuck draining a different pipe.
    // Each handle is touched by exactly one thread; the DispatchGroup wait below establishes a
    // happens-before edge so `outData`/`errData` are safe to read on the calling thread afterward.
    DispatchQueue.global().async {
      // Throwing variant + `try?`: if the child exits before consuming stdin, the write hits a
      // broken pipe — swallow it here rather than let the non-throwing `write(_:)` raise SIGPIPE
      // and take down the whole process.
      try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
      try? stdin.fileHandleForWriting.close()
    }
    nonisolated(unsafe) var outData = Data()
    nonisolated(unsafe) var errData = Data()
    let ioGroup = DispatchGroup()
    ioGroup.enter()
    DispatchQueue.global().async {
      outData = stdout.fileHandleForReading.readDataToEndOfFile(); ioGroup.leave()
    }
    ioGroup.enter()
    DispatchQueue.global().async {
      errData = stderr.fileHandleForReading.readDataToEndOfFile(); ioGroup.leave()
    }
    // Wait for both reads to finish (which happens when the child closes its ends / exits) with a
    // wall-clock cap. On timeout, terminate the child so the reads unblock, then throw.
    if ioGroup.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      _ = ioGroup.wait(timeout: .now() + 5)
      throw LLMError.providerFailed("claude -p timed out after \(Int(timeout))s")
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      let suffix = errText.isEmpty ? "" : ": \(errText.prefix(500))"
      throw LLMError.providerFailed("claude -p exit \(process.terminationStatus)\(suffix)")
    }
    return String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
