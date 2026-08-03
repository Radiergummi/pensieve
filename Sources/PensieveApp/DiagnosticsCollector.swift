import Foundation
import MetricKit
import os
import PensieveKit

/// Subscribes to MetricKit diagnostic + metric payloads and persists each as a timestamped JSON
/// file under `~/Library/Logs/Pensieve/diagnostics/`. Registered once on app launch.
final class DiagnosticsCollector: NSObject, MXMetricManagerSubscriber {
  nonisolated(unsafe) static let shared = DiagnosticsCollector()

  private let outputDir: URL = PensievePaths.logsDirectory()
    .appendingPathComponent("diagnostics", isDirectory: true)
  private let maxFiles = 30

  func start() {
    try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    prune()
    writeREADMEIfNeeded()
    MXMetricManager.shared.add(self)
    AppLog.app.info("DiagnosticsCollector registered")
  }

  func didReceive(_ payloads: [MXMetricPayload]) {
    for payload in payloads {
      write(payload.jsonRepresentation(), prefix: "metrics")
    }
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    for payload in payloads {
      write(payload.jsonRepresentation(), prefix: "diagnostic")
    }
  }

  private func write(_ data: Data, prefix: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let name = "\(prefix)-\(timestamp).json"
    let url = outputDir.appendingPathComponent(name)
    try? data.write(to: url, options: .atomic)
    AppLog.app.info("MetricKit payload written: \(name, privacy: .public)")
    prune()
  }

  private func prune() {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: outputDir, includingPropertiesForKeys: nil)
      .filter({ $0.pathExtension == "json" })
      .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    else { return }
    if files.count > maxFiles {
      for file in files.prefix(files.count - maxFiles) {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }

  private func writeREADMEIfNeeded() {
    let readme = PensievePaths.logsDirectory().appendingPathComponent("README.md")
    guard !FileManager.default.fileExists(atPath: readme.path) else { return }
    let content = """
    # Pensieve logs & diagnostics

    ## Structured logs (os.Logger → unified log)

    Stream live:
      log stream --predicate 'subsystem == "me.mazetti.pensieve"' --level debug

    Recent entries (last 1h):
      log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 1h --style compact

    Filter by category:
      log show --predicate 'subsystem == "me.mazetti.pensieve" AND category == "extraction"' --last 1h

    Export as JSON (for agent consumption):
      log show --predicate 'subsystem == "me.mazetti.pensieve"' --last 2h --style ndjson

    ## MetricKit diagnostics

    JSON files in ./diagnostics/ — one per MXMetricManager delivery (crashes, hangs, CPU/disk exceptions).
    Delivered by the system on the app's next launch after the event.

    ## Crash reports (automatic, no code)

    ~/Library/Logs/DiagnosticReports/Pensieve-*.ips
    """
    try? content.write(to: readme, atomically: true, encoding: .utf8)
  }
}
