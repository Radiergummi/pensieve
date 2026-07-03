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
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = Pipe()
    do { try process.run() } catch { throw LLMError.providerFailed("spawn: \(error)") }
    stdin.fileHandleForWriting.write(Data(prompt.utf8))
    stdin.fileHandleForWriting.closeFile()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw LLMError.providerFailed("claude -p exit \(process.terminationStatus)")
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
