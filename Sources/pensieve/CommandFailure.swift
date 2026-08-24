import Foundation

/// A user-facing runtime failure — "no project named 'x'", "unknown node".
///
/// Thrown, never printed: ArgumentParser writes `Error: <message>` to **stderr** and exits non-zero,
/// where the historical `print(...); return` wrote to stdout and exited **0**. That made every
/// failure invisible to the caller — `pensieve status typo` looked exactly like success to a shell,
/// a pipeline and a `set -e` script, and the message landed in the data stream rather than the
/// diagnostic one.
///
/// Deliberately NOT used by the hook-invoked commands. `prime` (SessionStart) and the `capture-*`
/// commands must exit 0 whatever happens — a non-zero exit from a git hook or a session hook is
/// exactly what the sacred capture path forbids — and `sync`'s relocation skip is a documented
/// "not now, try the next cycle", not a failure.
///
/// `ValidationError` stays the right type for an argument-SHAPE problem (wrong arity, unknown enum
/// value): ArgumentParser gives those exit code 64 plus the usage string. This one is for a
/// well-formed request that could not be satisfied.
struct CommandFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
