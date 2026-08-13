import Foundation
import SQLiteData

/// A loose end's lifecycle. A real enum rather than raw strings, like `NodeKind` / `NodeState` —
/// this codebase converted those precisely to kill the mistyped-literal hazard, and `status` is
/// compared at more call sites than either.
///
/// The raw values are the strings already on disk, so this type change needs **no migration**:
/// every stored row holds `"open"`, and `done` / `dropped` are new spellings that no historical row
/// can carry. The retired `"resolved"` spelling was never written by production code and is
/// deliberately given no alias.
///
/// `isOpen` is not defined here and is not edited anywhere: `status.eq(.open)` already excludes both
/// new cases, which is what propagates resolution through every existing consumer for free.
public enum LooseEndStatus: String, QueryBindable, Sendable {
  /// Live work. The only state that counts, ranks, or surfaces by default.
  case open
  /// Was a real loose end; it has been handled.
  case done
  /// Was a real loose end; it will not be handled. Distinct from a 👎 label, which asserts the
  /// extractor was wrong and feeds the salience training corpus — this asserts it was right.
  case dropped

  /// Anything that is not `open`. Named rather than spelled `!= .open` at call sites so the
  /// per-node and Completed feeds cannot disagree about what "closed" means.
  public var isClosed: Bool { self != .open }
}
