# Retroactive salience re-mine (one-shot)

Run once, after the salience + workSummary work is merged and installed
(`~/.local/bin/pensieve` rebuilt). Rebuilds the live open loose-end set through
the salience gate and backfills `workSummary` in one full re-parse. The salience
gate is stochastic, so we dry-run on a COPY and diff before touching the live store.

Live store: `~/Library/Application Support/Pensieve/pensieve.sqlite`

## 1. Back up
```bash
cp ~/Library/Application\ Support/Pensieve/pensieve.sqlite /tmp/pensieve.backup.sqlite
```

## 2. Dry-run on a copy, diff the drops
```bash
cp ~/Library/Application\ Support/Pensieve/pensieve.sqlite /tmp/pensieve.copy.sqlite
# snapshot the current open set
sqlite3 /tmp/pensieve.copy.sqlite "SELECT quote FROM looseEnds WHERE status='open' ORDER BY quote;" > /tmp/before.txt
# reset watermarks so a re-mine re-parses every session
sqlite3 /tmp/pensieve.copy.sqlite "UPDATE events SET extractedMessageCount=0, extractedTranscriptSize=0 WHERE kind='cc.session';"
sqlite3 /tmp/pensieve.copy.sqlite "DELETE FROM looseEnds WHERE status='open';"
# re-mine the copy (honours PENSIEVE_DB)
PENSIEVE_DB=/tmp/pensieve.copy.sqlite pensieve ingest
sqlite3 /tmp/pensieve.copy.sqlite "SELECT quote FROM looseEnds WHERE status='open' ORDER BY quote;" > /tmp/after.txt
# eyeball what the salience gate dropped — every dropped item must be genuinely non-salient
diff /tmp/before.txt /tmp/after.txt | grep '^<'
```
STOP and reconsider (raise the keep bias / escalate to claude -p) if the diff drops anything genuinely deferred/decision. Proceed only when the drops are all in-the-moment noise.

## 3. Pre-flight transcript existence (live)
For every open loose end, confirm its source transcript still exists — if any is
missing, deleting that loose end in step 5 would be **permanent** (it can never be
re-mined). The path lives in `events.detailJSON` under the `transcriptPath` key,
joined via `looseEnds.sourceEventID = events.id`.
```bash
sqlite3 ~/Library/Application\ Support/Pensieve/pensieve.sqlite \
  "SELECT DISTINCT json_extract(e.detailJSON, '\$.transcriptPath')
   FROM looseEnds l JOIN events e ON e.id = l.sourceEventID
   WHERE l.status='open';" \
| while IFS= read -r p; do
    if [ -n "$p" ] && [ ! -f "$p" ]; then echo "MISSING: $p"; fi
  done
```
**Proceed only if this prints nothing.** Any `MISSING:` line means an open loose end's
transcript is gone — abort and decide per-item (keep those loose ends, or accept the
loss) before running step 5.

## 4. Quiesce the daemon
```bash
launchctl unload ~/Library/LaunchAgents/com.pensieve.sync.plist
```

## 5. Reset + delete + re-mine (live)
```bash
sqlite3 ~/Library/Application\ Support/Pensieve/pensieve.sqlite \
  "DELETE FROM looseEnds WHERE status='open';
   UPDATE events SET extractedMessageCount=0, extractedTranscriptSize=0 WHERE kind='cc.session';"
pensieve ingest    # rebuilds the salient open set AND backfills workSummary in one pass (slow)
```
Report before/after open counts.

## 6. Reload the daemon
```bash
launchctl load ~/Library/LaunchAgents/com.pensieve.sync.plist
```
