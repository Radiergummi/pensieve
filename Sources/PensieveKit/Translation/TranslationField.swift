import Foundation

/// The fields Pensieve may translate — every one of them text its own models produced.
///
/// This enum IS the trust-gate boundary, expressed as a type rather than a convention. There is
/// deliberately no case naming a loose end's `quote` or a transcript message: verbatim provenance is
/// the north star, and a translated quote would no longer match the transcript it cites. A future
/// contributor cannot translate one by accident, because there is no value to pass.
public enum TranslationField: String, CaseIterable, Sendable {
  case narration
  case looseEndText
  case nodeName
  case nodeDescription
}
