import Foundation

/// Whole days from `start` to `end`, as the current `Calendar` counts them. Missing components
/// degrade to 0 — the behaviour every call site already had.
///
/// **The one dormancy/age formula.** It was spelled out four times: `NextQueries.ranked`,
/// `BriefingQueries.cards`, `NodeFactsQueries.facts` and `LooseEndQueries.attachEvents` each wrote
/// their own `Calendar.current.dateComponents([.day], from:to:).day ?? 0`, so a timezone or DST fix
/// would have landed in one of four places and the rendered "Nd dormant" could disagree with the
/// `daysDormant` that feeds `groundedScore`.
///
/// A free function rather than a method on anything: it belongs to no one type, and the same
/// precedent is already set by `groundedScore` in `NextQueries.swift`. The *thresholds* that read
/// this (14 days dormant / 3 days recently-active, `SmartLists`) are deliberately NOT here — they
/// are stated once already, as `SmartLists.compute`'s default arguments.
public func dayCount(from start: Date, to end: Date) -> Int {
  Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
}
