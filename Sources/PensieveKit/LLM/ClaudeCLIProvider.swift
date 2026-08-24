import Foundation
import os

/// Holds the in-flight `claude -p` child so a cancelled Task can terminate it. Cancelling a Swift
/// Task does nothing to a `Process`: without this the child ran on to its 120 s cap while the caller
/// that gave up on it (`narrateWithin`'s 3 s race) had already returned, holding the slot for two
/// more minutes. The lock also closes the spawn/cancel race — a cancellation that lands before the
/// child exists makes `adopt` refuse, and the caller kills what it just spawned.
final class ChildProcessSlot: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false

  /// Registers a freshly spawned child. False when cancellation already arrived — the caller must
  /// terminate the child it just spawned and abandon the call.
  func adopt(_ process: Process) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { return false }
    self.process = process
    return true
  }

  /// Terminates the adopted child (if it has spawned) and refuses any later adoption.
  func cancel() {
    lock.lock()
    cancelled = true
    let adopted = process
    process = nil
    lock.unlock()
    adopted?.terminate()
  }

  var wasCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

/// Fallback provider: shells out to `claude -p` (subscription auth, no API key).
public struct ClaudeCLIProvider: LLMProvider {
  private let run: @Sendable (String, ChildProcessSlot) throws -> String

  /// The real `claude -p` path, optionally pinned to a model (`pensieve label-suggest` pins Haiku).
  /// Goes through `shellRun`, which is the ONE spawn: it carries the cwd pin whose absence turned
  /// every model call into a captured Claude Code session (see `shellRun`).
  public init(model: String? = nil) {
    self.run = { prompt, child in try Self.shellRun(prompt, model: model, child: child) }
  }

  /// Injected runner — tests and any caller that stubs the subprocess out entirely. Such a runner
  /// spawns nothing, so there is no child to cancel.
  public init(run: @escaping @Sendable (String) throws -> String) {
    self.run = { prompt, _ in try run(prompt) }
  }

  public func complete(prompt: String) async throws -> String {
    Log.llm.debug("LLM prompt dispatched (len=\(prompt.count, privacy: .public), provider=claudeCLI)")
    // The subprocess is blocking, so run it on a background queue rather than parking a
    // Swift-concurrency cooperative worker for the whole call. `shellRun` bounds a hung
    // `claude -p` with its own wall-clock timeout (so the awaiting Task can't hang forever),
    // and the cancellation handler kills the child when the awaiting Task is cancelled.
    let run = self.run
    let child = ChildProcessSlot()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
          do { continuation.resume(returning: try run(prompt, child)) } catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: {
      child.cancel()
    }
  }

  /// Wall-clock cap on a single `claude -p` invocation. A hung child is terminated and the call
  /// throws rather than blocking a narration/extraction Task indefinitely.
  static let timeout: TimeInterval = 120

  /// Runs `claude -p` with the prompt on stdin; returns trimmed stdout. Uncancellable overload for
  /// callers outside a Task that could be cancelled.
  public static func shellRun(_ prompt: String, model: String? = nil) throws -> String {
    try shellRun(prompt, model: model, child: ChildProcessSlot())
  }

  /// The one `claude -p` spawn in the project. `model` pins `--model` when the caller wants a
  /// specific one; `child` lets a cancelled Task terminate the process.
  ///
  /// Resolves `claude` via `PATH` (`/usr/bin/env`). Interactive shells have it; a launchd context
  /// only does if the LaunchAgent injects a `PATH` covering the install dir — the CLI is the
  /// fallback provider (on-device Foundation Models is preferred when available), so this matters
  /// only on a machine without Foundation Models running under the daemon.
  static func shellRun(_ prompt: String, model: String?, child: ChildProcessSlot) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["claude", "-p"] + (model.map { ["--model", $0] } ?? [])
    // Pin the cwd. Without this the child inherits ours — which under the launchd daemon is `/`,
    // so every extraction call became a Claude Code session at the filesystem root, got captured
    // by the SessionEnd hook, and was re-ingested as "work" (a feedback loop that produced a
    // phantom project named "/"). A dedicated scratch dir is inert and recognizable; the ingester
    // refuses degenerate roots as a second line of defense (ProjectResolver.isDegenerateRoot).
    process.currentDirectoryURL = PensievePaths.llmScratchDirectory()
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    do { try process.run() } catch { throw LLMError.providerFailed("spawn: \(error)") }
    // Publish the child so a cancellation can kill it. A cancellation that beat the spawn means
    // nobody is waiting for this output — kill it immediately rather than run it to the cap.
    guard child.adopt(process) else {
      process.terminate()
      throw CancellationError()
    }
    Log.llm.debug("claude -p subprocess launched")
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
      Log.llm.error("claude -p timed out after \(Int(timeout), privacy: .public)s")
      throw LLMError.providerFailed("claude -p timed out after \(Int(timeout))s")
    }
    process.waitUntilExit()
    // A cancelled child exits on SIGTERM, which would otherwise be reported as a provider failure.
    // Report it as what it is, so the caller can tell "I gave up" from "the model broke".
    if child.wasCancelled { throw CancellationError() }
    guard process.terminationStatus == 0 else {
      let errText = (String(bytes: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let suffix = errText.isEmpty ? "" : ": \(errText.prefix(500))"
      Log.llm.error("claude -p exit \(process.terminationStatus, privacy: .public)")
      throw LLMError.providerFailed("claude -p exit \(process.terminationStatus)\(suffix)")
    }
    Log.llm.debug("LLM completion received (len=\(outData.count, privacy: .public))")
    return (String(bytes: outData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
