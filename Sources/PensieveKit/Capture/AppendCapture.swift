import Foundation

/// Encodes and appends one capture to the spool, and — the whole point of this function — makes a
/// failure VISIBLE without ever letting it reach the caller.
///
/// The capture path is sacred: it must never block or fail a `git commit` or a Claude Code session.
/// Every caller is therefore fire-and-forget, and the git hooks additionally discard stderr and
/// `exit 0`. The cost of that was a silent hole. `openSpool()` opens the spool with a `CREATE TABLE`
/// write transaction and a 5 s busy timeout, so a contended, full or unwritable spool throws — and
/// the two session hooks swallowed that with `try?` while the two git hooks let it exit non-zero
/// into a stderr the hook had already redirected to `/dev/null`. Either way the capture vanished
/// with no record anywhere. A dropped capture is a permanently missing commit or session, which is
/// the worst possible failure in a tool whose job is telling you what you were doing.
///
/// So: the error is still swallowed — failing the hook is not an option — but it is logged at
/// `error` level with the kind and the reason, where
/// `log show --predicate 'subsystem == "me.mazetti.pensieve"'` will find it. That turns a silent
/// hole into a loud one, which is the whole distinction this codebase keeps getting wrong.
///
/// Returns whether the capture was actually spooled, so a caller that wants an exit code can have
/// one. Callers on a hook path deliberately ignore it.
@discardableResult
public func appendCapture(kind: String, encoding payload: some Encodable) -> Bool {
  do {
    try openSpool().append(kind: kind, payload: try encodeJSON(payload))
    return true
  } catch {
    // `Log.ingest` rather than a `capture` category: `Log` has no capture category yet and lives in
    // `Support/`. The capture→ingest path is the closest existing one and this is its first step.
    Log.ingest.error("CAPTURE LOST (kind=\(kind, privacy: .public)): \(error, privacy: .public)")
    return false
  }
}
