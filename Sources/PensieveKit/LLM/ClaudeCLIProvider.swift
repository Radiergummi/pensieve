import Foundation

/// Fallback provider: shells out to `claude -p` (subscription auth, no API key).
public struct ClaudeCLIProvider: LLMProvider {
  private let run: @Sendable (String) throws -> String
  public init(run: @escaping @Sendable (String) throws -> String = ClaudeCLIProvider.shellRun) {
    self.run = run
  }

  public func complete(prompt: String) async throws -> String {
    try run(prompt)
  }

  /// Runs `claude -p` with the prompt on stdin; returns trimmed stdout.
  public static func shellRun(_ prompt: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["claude", "-p"]
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    do { try process.run() } catch { throw LLMError.providerFailed("spawn: \(error)") }
    // Drain stdin/stdout/stderr concurrently to avoid deadlock: if any one of these
    // pipes is fully written/read before the others start, the child can block writing
    // to a full pipe buffer (e.g. large stderr diagnostics) while the parent is stuck
    // draining a different pipe. Each handle is touched by exactly one thread; the
    // DispatchGroup wait below establishes a happens-before edge so `errData` is safe
    // to read on the calling thread afterward.
    DispatchQueue.global().async {
      stdin.fileHandleForWriting.write(Data(prompt.utf8))
      stdin.fileHandleForWriting.closeFile()
    }
    // Written on the background queue below and read on this thread only after
    // `stderrGroup.wait()` returns, which establishes a happens-before edge.
    nonisolated(unsafe) var errData = Data()
    let stderrGroup = DispatchGroup()
    stderrGroup.enter()
    DispatchQueue.global().async {
      errData = stderr.fileHandleForReading.readDataToEndOfFile()
      stderrGroup.leave()
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    stderrGroup.wait()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      let suffix = errText.isEmpty ? "" : ": \(errText.prefix(500))"
      throw LLMError.providerFailed("claude -p exit \(process.terminationStatus)\(suffix)")
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
