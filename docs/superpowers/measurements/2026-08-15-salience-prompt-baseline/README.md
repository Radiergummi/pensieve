# Salience prompt — baseline trial, 2026-08-15

20 loose ends labelled by `pensieve label-suggest --limit 20` (Haiku via `claude -p`), the **first
time the salience pipeline has ever been run** on this store. Result: `7 salient / 13 noise`, all 20
`quote-only` (no live transcript — consistent with ~85% of loose ends having lost theirs).

`trial-20.tsv` is `labelSuggestion \t text \t quote`. The store was restored to
`labelSuggestion = ''` afterwards, so this file is the only record and a new prompt starts from a
clean slate.

## Read

The **noise** calls look right — "spawn two independent sub-agents", "Resolve the threads", "can we
instead assert the error was reported?" are all in-the-moment instructions, correctly not durable.

The **salient** calls are weak. Of 7, roughly 2–3 are durable loose ends
("we'll probably need to merge develop in…", "Why don't we collect the project conventions up front…").
The rest are in-the-moment deliberation: "Maybe we should just rewrite the plan from scratch, though?",
"Moving to more pressing things."

This may be **as designed** — `SalienceReviewQueries` documents the intent as *"harvest the scarce
positives — Haiku's high recall puts nearly all true positives in its salient bucket"*, with Review
Suggestions as the human filter. Low salient precision is then the accepted cost of recall.

The consequence is what stopped the run: at this ratio a full pass marks ~340 salient / ~640 noise,
Review Suggestions goes from structurally empty to ~986 items to audit, and until that audit happens
the salient-first ordering promotes **unaudited** guesses above genuinely old work.
