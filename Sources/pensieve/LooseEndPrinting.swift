import Foundation
import PensieveKit

/// The CLI's quote-first loose-end renderer, in one place.
///
/// Quote first because the verbatim quote is the authoritative line — it is what the trust gate
/// actually verified — and the paraphrase is secondary. `status` and `looseends` each spelled this
/// two-line shape out itself, differing only in indentation, so a change to the citation format
/// landed in one of them.
func printLooseEnd(_ view: LooseEndView, indent: String = "") {
  print("\(indent)\u{201C}\(view.looseEnd.quote)\u{201D}")
  print("\(indent)  \u{21B3} \(view.looseEnd.text)  [\(view.looseEnd.role), \(view.ageDays)d]")
}
