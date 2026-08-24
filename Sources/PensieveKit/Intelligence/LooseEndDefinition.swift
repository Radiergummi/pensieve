import Foundation

/// What a loose end **is** — written once, quoted by every prompt that has to say it.
///
/// It used to be written out three times: the extraction prompt (`LooseEndExtractor.buildPrompt`),
/// the salience prompt (`SalienceClassifier.buildPrompt`) and the on-device drop-set schema
/// description (`FoundationModelsProvider`). Those three sit in series over the same items —
/// extraction proposes against one wording, salience judges against another — so tightening the
/// rule in one place left the others proposing exactly what it now rejects, and the examples are
/// the load-bearing part of the rule for a ~3B model.
///
/// Both halves are sentence fragments meant to be interpolated after a copula ("A LOOSE END is
/// \(isDeferredWork)"), so each prompt keeps its own framing while the definition stays single.
enum LooseEndDefinition {
  /// The positive half: what qualifies, with the canonical examples.
  static let isDeferredWork = """
  deferred, parked, or decision work the developer left OPEN for later — e.g. "we should also \
  migrate the auth tables", "let's do X later", "TODO: wire up the webhook", "don't forget the \
  rate limiter", "let's go with A instead of B"
  """

  /// The negative half: what looks like one and is not.
  static let isNotInTheMoment = """
  NOT an in-the-moment request the assistant simply carries out now — e.g. "read the spec", "can \
  you help me fix this?", "run the tests", "subagent-driven, let's go" — and not an \
  acknowledgement, approval, status check, checklist item or agent task brief ("looks good", \
  "carry on", "are you done")
  """
}
