# salience-labels.json — SYNTHETIC STARTER, not a go/no-go fixture

The 10 entries in `salience-labels.json` are hand-invented example quotes (not
sampled from any real store). They exist only so `SalienceEvalTests.swift`
compiles and is runnable end-to-end.

They are **not sufficient** for the actual A5 go/no-go decision. Before
running the eval for real:

1. Sample ~100–150 loose ends from the live store (read-only), weighted to
   the noisy nodes:
   ```bash
   sqlite3 -json "$HOME/Library/Application Support/Pensieve/pensieve.sqlite" \
     "SELECT quote FROM looseEnds WHERE status='open' ORDER BY RANDOM() LIMIT 150;"
   ```
2. Hand-label each row `{ "quote": "...", "salient": true|false }` and
   replace the contents of this file with that labeled set.
3. Run `PENSIEVE_SALIENCE_EVAL=1 make test FILTER=salienceEvalReport`
   and record precision/recall against the gate in the plan (Task A5 Step 1–3).

See `.superpowers/sdd/task-A5-brief.md` for the full runbook.
