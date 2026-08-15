# Salience: gold set, prompt rewrite, advisory labelling — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give salience classification a real gold set, rewrite its prompt for the advisory role it now serves, and run it automatically on new loose ends without letting it delete work or reorder the burn-down queue.

**Architecture:** Extraction stays lossless and unchanged. A bounded, best-effort pass in `SyncRunner` labels *recently created* loose ends via `claude -p` Haiku behind its own optional provider, writing `labelSuggestion` only. That feeds Review Suggestions (a triage surface), which produces the human labels the burn-down ordering actually trusts. A pre-registered numeric bar decides whether suggestions may ever reorder that queue.

**Tech Stack:** Swift 6 / SwiftPM (PensieveKit + tests), Swift Testing, SQLiteData 1.6.6 over GRDB, `claude -p` via `ClaudeCLIProvider`, Xcode 26.6 for the app/CLI targets.

**Spec:** `docs/superpowers/specs/2026-08-15-salience-prompt-and-advisory-labelling-design.md`

## Global Constraints

- **Extraction stays lossless.** `ExtractionRunner` must not gain a drop stage. Do not re-wire `SalienceClassifier.filter` into it.
- **Trust gate untouched.** Do not read, write, or reference `TranscriptVocabulary.injectionMarkers`, `TranscriptParser.isInjectedOrCommand`, or `isUserPrompt`.
- **`labelSuggestion` is machine-only; `label` is human-only.** `LooseEndCommands.suggest` is the only writer of the former. `LooseEndCommands.corpus` reads confirmed labels only — never suggestions.
- **No `EvalTask` registration** (spec § 5). Adding one fails the `registry ↔ config` guardrail unless a bar is added too; this work deliberately adds neither and records the exception in backlog F4.
- **No Python, ever. Swift only.**
- **Names are explicit — no abbreviations, no single letters.** `database`, `looseEnd`, `event`, `index`. Wire-format keys (`n`, `label`) are the exception and stay behind `CodingKeys`/`Decodable` structs.
- **SQLiteData predicates use `.eq(x)` / `.neq(x)`, never `== x`** (`==` is `unavailable` and will not compile).
- **SwiftLint runs `--strict` in CI**; files cap at 400 lines. Run `make lint` before every commit.
- **Run tests with `make test`** (optionally `FILTER=<name>`). `make all` = lint + test + build + CLI smoke.
- **The live store is real data.** Every query against `~/Library/Application Support/Pensieve/pensieve.sqlite` in this plan is read-only except where a step says otherwise and takes a backup first.
- **The pre-registered gate (spec § 4):** salient-first ordering may consume `labelSuggestion` only at **precision ≥ 0.50 and recall ≥ 0.70** on the held-out July 120. Not clearing it is a valid, successful outcome.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `docs/superpowers/measurements/2026-08-15-salience-prompt/sprobe1-relabel.swift` | Throwaway probe: pre-label the 122 thumbed quotes on the deferred axis, diff vs the stored thumb | 1 |
| `~/Library/Application Support/Pensieve/salience-corpus/labels-2026-08-15-dev.json` | The ~95-item dev gold set (out of git) | 1 |
| `Sources/PensieveKit/Query/LooseEndCommands.swift` | `LooseEndLabel` gains the suggestion-only `unsure` | 2 |
| `Sources/PensieveKit/Intelligence/SalienceClassifier.swift` | The prompt, the three-way decoder, `classify`, `filter` | 2, 3 |
| `Sources/PensieveKit/LLM/LLMProvider.swift` | `classifySalienceLabels` replaces `classifyNonSalientIndices` | 2, 3 |
| `Sources/PensieveKit/LLM/FoundationModelsProvider.swift` | Drops the dead `classifyNonSalientIndices` override + its schema | 3 |
| `Tests/PensieveKitTests/SalienceEvalTests.swift` | Reports gate metrics and July-comparable metrics | 4 |
| `Sources/PensieveKit/Intelligence/SalienceSuggester.swift` | Candidate selection gains a `createdAfter` window | 6 |
| `Sources/PensieveKit/Sync/SyncRunner.swift` | The optional salience pass | 7 |
| `Sources/pensieve/Commands/Sync.swift`, `Sources/PensieveSyncAgent/PensieveSyncAgent.swift` | Inject the Haiku salience provider | 7 |
| `Sources/PensieveKit/Query/LooseEndQueries.swift` | The comparator fork | 8 |
| `docs/superpowers/backlog.md`, `CLAUDE.md`, fixture README | Record outcomes and exceptions | 9 |

**Ordering note.** Task 1 ends in a blocking human checkpoint. Task 2 has no dependency on it and can be worked while waiting.

---

### Task 1: Build the dev gold set

**Files:**
- Create: `docs/superpowers/measurements/2026-08-15-salience-prompt/sprobe1-relabel.swift`
- Create: `docs/superpowers/measurements/2026-08-15-salience-prompt/README.md`
- Create (out of git): `~/Library/Application Support/Pensieve/salience-corpus/labels-2026-08-15-dev.json`

**Interfaces:**
- Consumes: nothing.
- Produces: `labels-2026-08-15-dev.json`, a `[{ "quote": String, "salient": Bool }]` array of ~95 items — the same shape `SalienceEvalTests` already decodes and `PENSIEVE_SALIENCE_LABELS` already points at.

**Why a standalone probe and not a CLI command:** this runs once. The precedent is `measurements/2026-08-13-slice5-label-quality/lprobe*.swift` — standalone `swiftc` files that import no PensieveKit type. Follow it.

- [ ] **Step 1: Export the two inputs**

Read-only against the live store. Run:

```bash
mkdir -p docs/superpowers/measurements/2026-08-15-salience-prompt
sqlite3 -json "$HOME/Library/Application Support/Pensieve/pensieve.sqlite" \
  "SELECT quote, label FROM looseEnds WHERE label != '';" \
  > /tmp/thumbs.json
jq 'length' /tmp/thumbs.json          # expect 122
jq 'length' "$HOME/Library/Application Support/Pensieve/salience-corpus/labels-2026-07-09.json"   # expect 120
```

Expected: `122` and `120`. If either differs, stop and report — the spec's arithmetic assumes these.

- [ ] **Step 2: Write the probe**

Create `docs/superpowers/measurements/2026-08-15-salience-prompt/sprobe1-relabel.swift`:

```swift
// THROWAWAY PROBE — build the salience dev gold set.
// Standalone by design (the retrieval + slice-5 probes set this precedent): imports no PensieveKit
// type. Reads /tmp/thumbs.json and the July label file; writes an adjudication worksheet.
import Foundation

struct Thumb: Decodable { let quote: String; let label: String }
struct JulyLabel: Decodable { let quote: String; let salient: Bool }

func load<T: Decodable>(_ path: String) -> [T] {
  guard let data = FileManager.default.contents(atPath: path),
        let rows = try? JSONDecoder().decode([T].self, from: data) else {
    fatalError("could not read \(path)")
  }
  return rows
}

/// One quote at a time. Slow (122 calls) but this runs once and per-item calls keep a bad
/// response from poisoning a whole batch.
func classify(_ quote: String) -> String {
  let prompt = """
  A LOOSE END is deferred, parked, or decision work a developer left open for later — \
  "we should also migrate the auth tables", "let's do X later", "TODO: wire up the webhook", \
  "let's go with A instead of B".

  It is NOT an in-the-moment request the assistant simply carried out at the time — "read the \
  spec", "can you fix this?", "run the tests", "subagent-driven, let's go", "merge to main". A \
  question the developer asked and had answered on the spot is also NOT a loose end, even when it \
  is about the product.

  Answer with exactly one word, "salient" or "noise", and nothing else.

  QUOTE: \(quote)
  """
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["claude", "-p", "--model", "claude-opus-4-8"]
  let stdin = Pipe(), stdout = Pipe()
  process.standardInput = stdin; process.standardOutput = stdout
  process.standardError = FileHandle.nullDevice
  try? process.run()
  try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
  try? stdin.fileHandleForWriting.close()
  let data = stdout.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  let reply = (String(data: data, encoding: .utf8) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  return reply.contains("salient") ? "salient" : "noise"
}

let thumbs: [Thumb] = load("/tmp/thumbs.json")
let july: [JulyLabel] = load(NSString(string:
  "~/Library/Application Support/Pensieve/salience-corpus/labels-2026-07-09.json").expandingTildeInPath)
let julyQuotes = Set(july.map(\.quote))

// The 27 quotes that also appear in the held-out July set are EXCLUDED from the dev set: tuning on
// them would leak the test set.
let devCandidates = thumbs.filter { !julyQuotes.contains($0.quote) }
FileHandle.standardError.write(Data("dev candidates: \(devCandidates.count)\n".utf8))

var agreed: [(quote: String, salient: Bool)] = []
var disputed: [(quote: String, thumb: String, model: String)] = []
for (offset, row) in devCandidates.enumerated() {
  let model = classify(row.quote)
  FileHandle.standardError.write(Data("[\(offset + 1)/\(devCandidates.count)] \(model)\n".utf8))
  if model == row.label {
    agreed.append((row.quote, model == "salient"))
  } else {
    disputed.append((row.quote, row.label, model))
  }
}

// Agreements are accepted as-is; only disagreements need a human.
let agreedJSON = agreed.map { ["quote": $0.quote, "salient": $0.salient] as [String: Any] }
let agreedData = try! JSONSerialization.data(withJSONObject: agreedJSON, options: [.prettyPrinted])
try! agreedData.write(to: URL(fileURLWithPath: "/tmp/salience-agreed.json"))

var worksheet = "salient\tthumb\tmodel\tquote\n"
for row in disputed {
  let flat = row.quote.replacingOccurrences(of: "\t", with: " ")
                      .replacingOccurrences(of: "\n", with: " ¶ ")
  worksheet += "?\t\(row.thumb)\t\(row.model)\t\(flat)\n"
}
try! worksheet.write(toFile: "/tmp/salience-worksheet.tsv", atomically: true, encoding: .utf8)
print("agreed: \(agreed.count) → /tmp/salience-agreed.json")
print("disputed: \(disputed.count) → /tmp/salience-worksheet.tsv  (fill column 1 with salient|noise)")
```

- [ ] **Step 3: Run the probe**

```bash
swiftc -O docs/superpowers/measurements/2026-08-15-salience-prompt/sprobe1-relabel.swift -o /tmp/sprobe1 && /tmp/sprobe1
```

Expected: `dev candidates: 95` on stderr, then per-item progress, then a summary naming both output files. Roughly 30–50 disputed.

If `claude -p` fails on the first item, stop — every subsequent item will fail the same way, and the probe would silently label all 95 `noise` (the fallback branch). Check `claude -p 'say hi'` works first.

- [ ] **Step 4: BLOCKING HUMAN CHECKPOINT — adjudication**

Hand the user `/tmp/salience-worksheet.tsv`. They fill column 1 with `salient` or `noise` for each row. Their answer is authoritative; the `thumb` and `model` columns are context only.

**Do not proceed past this step without the filled worksheet.** Do not guess the labels, and do not fall back to either the thumb or the model column — the whole point of this task is that neither is the target.

- [ ] **Step 5: Merge into the dev gold set**

```bash
mkdir -p "$HOME/Library/Application Support/Pensieve/salience-corpus"
awk -F'\t' 'NR>1 && $1 != "?" {
  gsub(/"/, "\\\"", $4);
  printf "%s{\"quote\": \"%s\", \"salient\": %s}", (n++ ? ",\n  " : ""), $4, ($1=="salient" ? "true" : "false")
}' /tmp/salience-worksheet.tsv > /tmp/salience-adjudicated-body.txt
printf '[\n  %s\n]\n' "$(cat /tmp/salience-adjudicated-body.txt)" > /tmp/salience-adjudicated.json

jq -s '.[0] + .[1]' /tmp/salience-agreed.json /tmp/salience-adjudicated.json \
  > "$HOME/Library/Application Support/Pensieve/salience-corpus/labels-2026-08-15-dev.json"

jq 'length, (map(select(.salient)) | length)' \
  "$HOME/Library/Application Support/Pensieve/salience-corpus/labels-2026-08-15-dev.json"
```

Expected: `95` and a positive count somewhere in the 25–50 range.

Sanity check that no test-set item leaked in — this must print `0`:

```bash
jq -s '(.[1] | map(.quote)) as $test | .[0] | map(select(.quote as $q | $test | index($q))) | length' \
  "$HOME/Library/Application Support/Pensieve/salience-corpus/labels-2026-08-15-dev.json" \
  "$HOME/Library/Application Support/Pensieve/salience-corpus/labels-2026-07-09.json"
```

- [ ] **Step 6: Write the measurement README**

Create `docs/superpowers/measurements/2026-08-15-salience-prompt/README.md` recording: the dev/test split and why they are not merged (the July 120 is the only random sample; 27 quotes overlap), the counts from Step 5, the model used to pre-label, the disputed count, and the fact that the dev file is deliberately out of git. Leave a `## Results` heading empty — Task 5 fills it.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/measurements/2026-08-15-salience-prompt/
git commit -m "measure: build the salience dev gold set (95 items, adjudicated)"
```

---

### Task 2: Three-way label plumbing

**Files:**
- Modify: `Sources/PensieveKit/Query/LooseEndCommands.swift:7-11`
- Modify: `Sources/PensieveKit/Intelligence/SalienceClassifier.swift`
- Modify: `Sources/PensieveKit/LLM/LLMProvider.swift`
- Test: `Tests/PensieveKitTests/SalienceClassifierTests.swift`

**Interfaces:**
- Consumes: `firstJSONArray(in:)` from `Sources/PensieveKit/Intelligence/JSONExtraction.swift` (internal to PensieveKit, already used by `IntentClassifier.decodeIndices`).
- Produces:
  - `LooseEndLabel.unsure: String` (`"unsure"`)
  - `SalienceClassifier.decodeLabels(_ raw: String) -> [Int: String]?`
  - `LLMProvider.classifySalienceLabels(prompt: String) async throws -> [Int: String]`

This task adds the new path only. Task 3 switches callers over and deletes the old one.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/SalienceClassifierTests.swift`:

```swift
@Test func decodeLabelsParsesLabelObjects() {
  let decoded = SalienceClassifier.decodeLabels(#"[{"n":0,"label":"salient"},{"n":1,"label":"noise"}]"#)
  #expect(decoded == [0: LooseEndLabel.salient, 1: LooseEndLabel.noise])
}

@Test func decodeLabelsIgnoresUnrecognisedLabels() {
  let decoded = SalienceClassifier.decodeLabels(#"[{"n":0,"label":"maybe"},{"n":1,"label":"unsure"}]"#)
  #expect(decoded == [1: LooseEndLabel.unsure])
}

@Test func decodeLabelsFindsArrayInsideProse() {
  let decoded = SalienceClassifier.decodeLabels("Here you go:\n[{\"n\":3,\"label\":\"noise\"}]\nHope that helps")
  #expect(decoded == [3: LooseEndLabel.noise])
}

@Test func decodeLabelsReturnsNilWhenUnparseable() {
  #expect(SalienceClassifier.decodeLabels("no array here") == nil)
}

@Test func classifySalienceLabelsDefaultExtensionThrowsOnUnparseable() async {
  await #expect(throws: LLMError.self) {
    _ = try await RawReply(reply: "no array here").classifySalienceLabels(prompt: "x")
  }
}
```

`RawReply` already exists at the top of that file (`SalienceClassifierTests.swift:5-8`) and needs no change.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
make test FILTER=decodeLabels
```

Expected: FAIL — `type 'SalienceClassifier' has no member 'decodeLabels'`.

- [ ] **Step 3: Add the `unsure` constant**

In `Sources/PensieveKit/Query/LooseEndCommands.swift`, extend the enum:

```swift
public enum LooseEndLabel {
  public static let unlabeled = ""
  public static let salient = "salient"
  public static let noise = "noise"
  /// Suggestion-only: the model saw the quote and did not commit. Never written to the human
  /// `label` — `LooseEndCommands.corpus` reads confirmed labels, so an unsure suggestion can
  /// never enter the training corpus. Additive on a STRICT TEXT column; no migration.
  public static let unsure = "unsure"
}
```

- [ ] **Step 4: Add the decoder**

In `Sources/PensieveKit/Intelligence/SalienceClassifier.swift`, inside `SalienceClassifier`:

```swift
  /// The three values a suggestion may take. Anything else the model emits is discarded rather
  /// than stored, so a hallucinated label can never reach the column.
  static let suggestionLabels: Set<String> = [LooseEndLabel.salient, LooseEndLabel.noise, LooseEndLabel.unsure]

  private struct LabeledIndex: Decodable {
    let n: Int          // wire-format key; see CodingKeys note in the plan's Global Constraints
    let label: String
  }

  /// `[{"n":0,"label":"salient"}, …]` → `[index: label]`. Mirrors `IntentClassifier.decodeIndices`:
  /// nil means "not a parseable answer" so the caller can fail open. Unrecognised labels are
  /// dropped, and a dropped index reads as `unsure` at the call site.
  static func decodeLabels(_ raw: String) -> [Int: String]? {
    guard let slice = firstJSONArray(in: raw), let data = slice.data(using: .utf8),
          let rows = try? JSONDecoder().decode([LabeledIndex].self, from: data)
    else { return nil }
    var labels: [Int: String] = [:]
    for row in rows where suggestionLabels.contains(row.label) { labels[row.n] = row.label }
    return labels
  }
```

- [ ] **Step 5: Add the protocol method**

In `Sources/PensieveKit/LLM/LLMProvider.swift`, add to the `LLMProvider` protocol beside `classifyNonSalientIndices`:

```swift
  /// Per-item salience labels for a batch prompt, keyed by the item's `[n]` index. The default
  /// decodes JSON from `complete` and **throws** when the response is not a parseable label array,
  /// so the caller can fail open. A missing index is not an error — it reads as `unsure`.
  func classifySalienceLabels(prompt: String) async throws -> [Int: String]
```

And to the `public extension LLMProvider` block:

```swift
  func classifySalienceLabels(prompt: String) async throws -> [Int: String] {
    guard let labels = SalienceClassifier.decodeLabels(try await complete(prompt: prompt)) else {
      throw LLMError.providerFailed("salience response was not a parseable label array")
    }
    return labels
  }
```

**No `FoundationModelsProvider` override.** On-device FM measured recall 0.68 on this task (`docs/superpowers/salience-eval-2026-07-09.md`) and is not the provider this pipeline uses; giving it a guided-generation schema would imply it is supported. It inherits the default.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
make test FILTER=decodeLabels && make test FILTER=classifySalienceLabels
```

Expected: PASS.

- [ ] **Step 7: Lint and commit**

```bash
make lint
git add Sources/PensieveKit/Query/LooseEndCommands.swift \
        Sources/PensieveKit/Intelligence/SalienceClassifier.swift \
        Sources/PensieveKit/LLM/LLMProvider.swift \
        Tests/PensieveKitTests/SalienceClassifierTests.swift
git commit -m "feat: add three-way salience labels (salient/noise/unsure)"
```

---

### Task 3: Rewrite the prompt and switch every caller to the three-way path

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/SalienceClassifier.swift:63-87` (prompt), `:25-38` (`filter`)
- Modify: `Sources/PensieveKit/Intelligence/SalienceSuggester.swift:63-78`
- Modify: `Sources/PensieveKit/LLM/LLMProvider.swift`, `Sources/PensieveKit/LLM/FoundationModelsProvider.swift` (delete the old path)
- Test: `Tests/PensieveKitTests/SalienceClassifierTests.swift`, `Tests/PensieveKitTests/SalienceSuggesterTests.swift`

**Interfaces:**
- Consumes: `LooseEndLabel.unsure`, `SalienceClassifier.decodeLabels`, `LLMProvider.classifySalienceLabels` (Task 2).
- Produces: `SalienceClassifier.classify(_ items: [(quote: String, context: String)]) async -> [String]?` — one label per item in input order, `nil` on provider failure.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/SalienceClassifierTests.swift`:

```swift
private struct FixedLabels: LLMProvider {
  let labels: [Int: String]
  func complete(prompt: String) async throws -> String { "[]" }
  func classifySalienceLabels(prompt: String) async throws -> [Int: String] { labels }
}
private struct ThrowLabels: LLMProvider {
  func complete(prompt: String) async throws -> String { "[]" }
  func classifySalienceLabels(prompt: String) async throws -> [Int: String] {
    throw LLMError.providerFailed("boom")
  }
}

@Test func classifyReturnsOneLabelPerItemInOrder() async {
  let items = [(quote: "a", context: ""), (quote: "b", context: "")]
  let labels = await SalienceClassifier(provider: FixedLabels(labels: [0: "noise", 1: "salient"]))
    .classify(items)
  #expect(labels == [LooseEndLabel.noise, LooseEndLabel.salient])
}

@Test func classifyFillsMissingIndicesWithUnsure() async {
  let items = [(quote: "a", context: ""), (quote: "b", context: "")]
  let labels = await SalienceClassifier(provider: FixedLabels(labels: [1: "salient"])).classify(items)
  #expect(labels == [LooseEndLabel.unsure, LooseEndLabel.salient])
}

@Test func classifyReturnsNilOnProviderFailure() async {
  let labels = await SalienceClassifier(provider: ThrowLabels()).classify([(quote: "a", context: "")])
  #expect(labels == nil)
}

@Test func filterDropsOnlyNoiseAndKeepsUnsure() async {
  let ends = [vle("noisy", at: 0), vle("unsure one", at: 1), vle("real", at: 2)]
  let msgs = [um(0, "noisy"), um(1, "unsure one"), um(2, "real")]
  let provider = FixedLabels(labels: [0: "noise", 1: "unsure", 2: "salient"])
  let kept = await SalienceClassifier(provider: provider).filter(ends, messages: msgs)
  #expect(kept.map(\.quote) == ["unsure one", "real"])
}

@Test func filterFailsOpenOnProviderFailure() async {
  let ends = [vle("a", at: 0), vle("b", at: 1)]
  let msgs = [um(0, "a"), um(1, "b")]
  let kept = await SalienceClassifier(provider: ThrowLabels()).filter(ends, messages: msgs)
  #expect(kept.count == 2)
}

@Test func promptAsksForLabelObjectsAndDoesNotTellTheModelToKeepWhenUnsure() {
  let prompt = SalienceClassifier.buildPrompt([(quote: "migrate the auth tables later", context: "")])
  #expect(prompt.contains(#""label""#))
  #expect(prompt.contains("unsure"))
  // The instruction that caused precision 0.23. Its removal is the point of this task; this
  // assertion is what stops it being reintroduced by a well-meaning later edit.
  #expect(!prompt.contains("do NOT include it"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
make test FILTER=classify
```

Expected: FAIL — `value of type 'SalienceClassifier' has no member 'classify'`.

- [ ] **Step 3: Pick the few-shot examples from the dev set**

Six examples, three of each class, taken from the dev gold set built in Task 1. Print candidates:

```bash
jq -r '.[] | select(.salient) | .quote' \
  "$HOME/Library/Application Support/Pensieve/salience-corpus/labels-2026-08-15-dev.json" \
  | awk 'length < 120' | head -12
jq -r '.[] | select(.salient | not) | .quote' \
  "$HOME/Library/Application Support/Pensieve/salience-corpus/labels-2026-08-15-dev.json" \
  | awk 'length < 120' | head -12
```

Pick three of each. Prefer the ones that are *not* obvious — the value of a few-shot example is in the borderline case. Every dev-set quote is by construction absent from the held-out July file, so no example can leak the test set.

- [ ] **Step 4: Rewrite the prompt**

Replace the body of `buildPrompt(_ items:)` in `Sources/PensieveKit/Intelligence/SalienceClassifier.swift`. Keep the enclosing function signature and its "ONE definition" doc comment exactly as they are — `filter` and `SalienceSuggester` both call it and must not drift.

```swift
  static func buildPrompt(_ items: [(quote: String, context: String)]) -> String {
    let body = items.enumerated().map { (index, item) in
      "[\(index)] QUOTE: \(item.quote)\nCONTEXT:\n\(item.context)"
    }.joined(separator: "\n\n")
    return """
    Each item below is a candidate LOOSE END quoted from a developer's message, with surrounding \
    context when it is available.

    A LOOSE END is deferred, parked, or decision work the developer left open for later — e.g. \
    "we should also migrate the auth tables", "let's do X later", "TODO: wire up the webhook", \
    "let's go with A instead of B".

    It is NOT an in-the-moment request the assistant simply carried out at the time — e.g. "read \
    the spec", "can you fix this?", "run the tests", "subagent-driven, let's go", "merge to main", \
    "looks good, write the plan". A question the developer asked and had answered on the spot is \
    also NOT a loose end, even when it is about the product.

    CONTEXT is often empty. Most quotes reach you with no surrounding transcript because the \
    session file is gone, so an empty CONTEXT is not evidence either way — judge the quote as \
    written rather than treating missing context as a signal.

    Label every item exactly one of:
      "salient" — deferred, parked, or decision work left open for later
      "noise"   — an in-the-moment request, a question answered on the spot, or talk about \
    running the session
      "unsure"  — the quote is genuinely ambiguous on its own

    Use "unsure" only for a truly ambiguous quote, not to avoid committing.

    Examples:
    <<< SIX EXAMPLES FROM STEP 3, one per line, as: QUOTE: … → salient|noise >>>

    Return ONLY a JSON array with one object per item, no prose:
    [{"n": 0, "label": "salient"}, {"n": 1, "label": "noise"}]

    Items:
    \(body)
    """
  }
```

Replace the `<<< … >>>` line with the six chosen examples. Do not leave the placeholder in.

- [ ] **Step 5: Re-express `filter` over `classify`**

Replace `SalienceClassifier.filter` and add `classify`:

```swift
  /// Per-item labels for one batch, in input order. `nil` = the provider failed, which is
  /// distinct from "every item is unsure" and lets a caller write nothing rather than write
  /// wrong. An empty input is an empty answer, not a failure.
  public func classify(_ items: [(quote: String, context: String)]) async -> [String]? {
    guard !items.isEmpty else { return [] }
    guard let labels = try? await provider.classifySalienceLabels(prompt: Self.buildPrompt(items))
    else { return nil }
    return (0..<items.count).map { labels[$0] ?? LooseEndLabel.unsure }
  }

  public func filter(_ ends: [VerifiedLooseEnd], messages: [TranscriptMessage]) async -> [VerifiedLooseEnd] {
    guard !ends.isEmpty else { return [] }
    var kept: [VerifiedLooseEnd] = []
    for batch in Self.batches(ends, messages: messages, budget: batchCharBudget) {
      let items = batch.map { (quote: $0.quote, context: Self.contextWindow(for: $0, messages: messages)) }
      guard let labels = await classify(items) else {
        kept.append(contentsOf: batch)      // hard error: fail open, keep all
        continue
      }
      // Only an explicit `noise` drops. `unsure` keeps — this stage never deletes captured work,
      // and the salient/unsure split is consumed by the audit queue, not by a deletion decision.
      for (index, end) in batch.enumerated() where labels[index] != LooseEndLabel.noise {
        kept.append(end)
      }
    }
    return kept
  }
```

- [ ] **Step 6: Switch `SalienceSuggester` to per-item labels**

In `Sources/PensieveKit/Intelligence/SalienceSuggester.swift`, replace the batch loop (currently `:65-78`):

```swift
    var suggested = 0, salient = 0, noise = 0, unsure = 0, skipped = 0
    let classifier = SalienceClassifier(provider: provider, batchCharBudget: batchCharBudget)
    for batch in Self.batches(items, budget: batchCharBudget) {
      guard let labels = await classifier.classify(batch.map { (quote: $0.quote, context: $0.context) }) else {
        skipped += batch.count            // provider failure: write nothing, retried on a later run
        continue
      }
      for (index, item) in batch.enumerated() {
        let label = labels[index]
        _ = try? LooseEndCommands.suggest(database, id: item.id, label: label)
        suggested += 1
        switch label {
        case LooseEndLabel.salient: salient += 1
        case LooseEndLabel.noise: noise += 1
        default: unsure += 1
        }
      }
    }
    return Summary(candidates: capped.count, suggested: suggested, salient: salient,
                   noise: noise, unsure: unsure, quoteOnly: quoteOnly, skipped: skipped)
```

Add `unsure` to `SalienceSuggester.Summary` (`:11-13`):

```swift
    public let candidates: Int, suggested: Int, salient: Int, noise: Int, unsure: Int
    public let quoteOnly: Int, skipped: Int
```

Update the print in `Sources/pensieve/Commands/LabelSuggest.swift:37-40` to include `\(result.unsure) unsure`.

- [ ] **Step 7: Delete the orphaned old path**

`classifyNonSalientIndices` now has no production caller. Leaving a second salience entry point is exactly the two-paths-that-drift hazard this codebase keeps getting bitten by, so remove it:

```bash
grep -rn "classifyNonSalientIndices\|nonSalientIndicesSchema" Sources Tests
```

Delete: the protocol requirement and default extension in `LLMProvider.swift`; the `FoundationModelsProvider.classifyNonSalientIndices` override and its `nonSalientIndicesSchema()` builder; the tests `nonSalientDefaultExtensionParsesIntArray` and `nonSalientDefaultExtensionThrowsOnUnparseable` (`SalienceClassifierTests.swift:10-19`), which test a method that no longer exists.

**Convert, do not delete, the four test stubs.** `DropIndices` / `ThrowSalience` (`SalienceClassifierTests.swift:21-29`) and `DropSet` / `AlwaysThrows` (`SalienceSuggesterTests.swift:7-16`) each back tests that must keep passing — in particular `suggesterWritesNothingWhenProviderFails` (`SalienceSuggesterTests.swift:66-74`) is the spec's write-nothing-on-provider-failure guarantee. Replace each stub's `classifyNonSalientIndices` body with a `classifySalienceLabels` equivalent, mapping a drop-index list to `[index: "noise"]`, and update the tests that construct them. Where the new `FixedLabels` / `ThrowLabels` from Step 1 already cover a stub's only remaining use, collapse onto those instead of keeping two.

- [ ] **Step 8: Run the full suite**

```bash
make test
```

Expected: PASS, with the suite total down by 2 (the two deleted `nonSalient*` tests) and up by the 7 added in Steps 1 and Task 2. Record the number.

- [ ] **Step 9: Lint and commit**

```bash
make lint
git add -A Sources Tests
git commit -m "feat: rewrite the salience prompt for advisory use, drop the keep-when-unsure bias"
```

---

### Task 4: Report both metric pairs in the eval harness

**Files:**
- Modify: `Tests/PensieveKitTests/SalienceEvalTests.swift`

**Interfaces:**
- Consumes: `SalienceClassifier.classify` (Task 3).
- Produces: the printed report Task 5 records.

**Why this task exists.** The harness currently measures "kept vs dropped". Under three-way labels, "kept" is `salient ∪ unsure`, but the gate in spec § 4 governs promotion of `labelSuggestion == salient` only. Reporting only one of those would either mismeasure the gate or break comparability with the July baseline. Report both, labelled.

- [ ] **Step 1: Replace the measurement body**

In `Tests/PensieveKitTests/SalienceEvalTests.swift`, replace everything from `let ends = labels.map {` to the end of the test with:

```swift
  // Each quote is its own item with an empty context — the same degenerate-context condition the
  // July baseline ran under, which is what makes the two comparable. See the caveat in
  // docs/superpowers/salience-eval-2026-07-09.md.
  let classifier = SalienceClassifier(provider: provider)
  var predicted: [String] = []
  for item in labels {
    let batch = await classifier.classify([(quote: item.quote, context: "")])
    predicted.append(batch?.first ?? LooseEndLabel.unsure)
  }

  func scores(positiveWhen isPositive: (String) -> Bool) -> (precision: Double, recall: Double, positives: Int) {
    let predictedPositive = zip(labels, predicted).filter { isPositive($0.1) }
    let truePositive = predictedPositive.filter { $0.0.salient }.count
    let actualPositive = labels.filter(\.salient).count
    return (Double(truePositive) / Double(max(1, predictedPositive.count)),
            Double(truePositive) / Double(max(1, actualPositive)),
            predictedPositive.count)
  }

  // GATE metric (spec § 4): only an explicit `salient` promotes an item, so only `salient`
  // counts as a predicted positive.
  let gate = scores { $0 == LooseEndLabel.salient }
  // JULY-COMPARABLE metric: the old drop-set harness kept everything it did not drop, which is
  // `salient` plus `unsure`. Reported so the 0.947/0.23 baseline stays a like-for-like comparison.
  let kept = scores { $0 != LooseEndLabel.noise }

  let counts = Dictionary(grouping: predicted, by: { $0 }).mapValues(\.count)
  print("SALIENCE EVAL — n=\(labels.count) actualSalient=\(labels.filter(\.salient).count)")
  print("SALIENCE EVAL — labels: \(counts)")
  print("SALIENCE EVAL — GATE (predicted=salient): precision=\(gate.precision) recall=\(gate.recall) promoted=\(gate.positives)")
  print("SALIENCE EVAL — KEPT (predicted!=noise): precision=\(kept.precision) recall=\(kept.recall) kept=\(kept.positives)")
  print("SALIENCE EVAL — gate bar is precision>=0.50 AND recall>=0.70 on the held-out set")

  // Every genuine loose end the model called `noise` — the expensive error, and the list worth
  // reading by hand when a number moves.
  for (item, label) in zip(labels, predicted) where item.salient && label == LooseEndLabel.noise {
    print("  MISSED: \(item.quote)")
  }
```

Also delete the stale `NOTE:` block at `SalienceEvalTests.swift:5-8` — it claims the real gold set does not exist, which has been untrue since July — and replace it with:

```swift
// Gold sets (both out of git; point the harness with PENSIEVE_SALIENCE_LABELS):
//   dev  ~/Library/Application Support/Pensieve/salience-corpus/labels-2026-08-15-dev.json  (95)
//   test ~/Library/Application Support/Pensieve/salience-corpus/labels-2026-07-09.json      (120, held out)
// Fixtures/salience-labels.json remains a 10-quote synthetic seed so this file compiles anywhere.
```

- [ ] **Step 2: Verify it still compiles and is skipped without the env var**

```bash
make test FILTER=salienceEval
```

Expected: PASS, instantly, with no model calls — the test returns early unless `PENSIEVE_SALIENCE_EVAL=1`.

- [ ] **Step 3: Smoke-run against the synthetic fixture**

```bash
PENSIEVE_SALIENCE_EVAL=1 PENSIEVE_SALIENCE_EVAL_PROVIDER=claude \
  make test FILTER=salienceEval
```

Expected: the five `SALIENCE EVAL —` lines over the 10 synthetic quotes. This checks the plumbing, not the quality — 10 invented quotes prove nothing about the prompt.

- [ ] **Step 4: Lint and commit**

```bash
make lint
git add Tests/PensieveKitTests/SalienceEvalTests.swift
git commit -m "test: report gate and July-comparable salience metrics"
```

---

### Task 5: Measure, iterate on dev, then measure the held-out set once

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/SalienceClassifier.swift` (prompt revisions only)
- Modify: `docs/superpowers/measurements/2026-08-15-salience-prompt/README.md`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: the numbers, and the § 4 gate decision that Task 8's follow-up depends on.

**Discipline for this task, stated before any number is seen:** iterate freely on the dev set. Run the **held-out** set at most **twice** — once when the dev numbers stop improving, and, if a revision is made after seeing that result, once more at the very end. Every additional held-out run turns the test set into a second dev set and the numbers stop meaning what they claim.

- [ ] **Step 1: Baseline the new prompt on dev**

```bash
PENSIEVE_SALIENCE_EVAL=1 PENSIEVE_SALIENCE_EVAL_PROVIDER=claude \
  PENSIEVE_CLAUDE_MODEL=claude-haiku-4-5-20251001 \
  PENSIEVE_SALIENCE_LABELS="$HOME/Library/Application Support/Pensieve/salience-corpus/labels-2026-08-15-dev.json" \
  make test FILTER=salienceEval 2>&1 | tee /tmp/salience-dev-run1.txt
```

Record the GATE precision/recall and the label counts in the README under `## Results`, tagged `dev, prompt v1`.

- [ ] **Step 2: Iterate, at most three revisions**

If GATE precision is below 0.50 on dev, revise the prompt and re-run Step 1 with an incremented tag. Read the `MISSED:` lines and the label counts before each revision — a large `unsure` count and a low precision call for different fixes.

Cap at three revisions. If three do not clear 0.50 on dev, stop and report that: the honest finding is that this prompt shape does not reach the bar, and further iteration on the dev set will produce a number that does not survive the held-out run.

Commit each revision separately so the README's tags map to real commits:

```bash
make lint && make test
git add Sources/PensieveKit/Intelligence/SalienceClassifier.swift \
        docs/superpowers/measurements/2026-08-15-salience-prompt/README.md
git commit -m "measure: salience prompt v2 — dev precision X.XX recall X.XX"
```

- [ ] **Step 3: The held-out run**

Only once dev has stopped improving:

```bash
PENSIEVE_SALIENCE_EVAL=1 PENSIEVE_SALIENCE_EVAL_PROVIDER=claude \
  PENSIEVE_CLAUDE_MODEL=claude-haiku-4-5-20251001 \
  PENSIEVE_SALIENCE_LABELS="$HOME/Library/Application Support/Pensieve/salience-corpus/labels-2026-07-09.json" \
  make test FILTER=salienceEval 2>&1 | tee /tmp/salience-heldout.txt
```

- [ ] **Step 4: Write the verdict**

In the README's `## Results`, record a table: prompt version, dev GATE precision/recall, held-out GATE precision/recall, held-out KEPT precision/recall, and the July baseline (`Haiku kept-precision 0.23 / recall 0.947`, `on-device 0.17–0.19 / 0.68`, `un-gated floor 0.158`) for comparison.

Then state the gate decision explicitly, in one of two forms:

> **Gate CLEARED** — held-out GATE precision `X.XX` ≥ 0.50 and recall `X.XX` ≥ 0.70. Salient-first ordering on the burn-down queue may be enabled; see the deferred item in Task 8.

> **Gate NOT cleared** — held-out GATE precision `X.XX`. Salient-first ordering stays off. This is a recorded outcome, not a failure: the burn-down queue keeps its honest oldest-first ordering, and Review Suggestions still runs.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/measurements/2026-08-15-salience-prompt/README.md
git commit -m "measure: salience held-out result and gate decision"
```

---

### Task 6: Bound `SalienceSuggester` to a lookback window

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/SalienceSuggester.swift:28-45`
- Test: `Tests/PensieveKitTests/SalienceSuggesterTests.swift`

**Interfaces:**
- Produces: `SalienceSuggester.run(_ database:limit:force:createdAfter:) async throws -> Summary`, where `createdAfter: Date? = nil` means "no window" (the CLI backfill's existing behaviour, unchanged).

**Why:** without a window, the sync pass's candidate query matches the entire 986-row backlog and the daemon grinds through it a cap at a time over hours — the unattended mass-labelling the spec says must stay a deliberate human decision. `createdAt >= cycleStart` would also avoid that but silently breaks the retry guarantee: an item whose batch failed on a provider error would never be a candidate again.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/SalienceSuggesterTests.swift`. First extend the existing `seedLE` helper (`:19-37`) with a `createdAt` parameter, passing it through to the `LooseEnd` initializer, which already accepts one:

```swift
private func seedLE(_ database: any DatabaseWriter, quote: String, label: String = "",
                    suggestion: String = "", status: LooseEndStatus = .open,
                    messageIndex: Int = 0, createdAt: Date = Date()) throws -> (UUID, UUID) {
```

and in the `LooseEnd(...)` construction inside it add `createdAt: createdAt`.

Then the tests:

This file's own helpers are `tempURL(_:)`, `seedLE(...)`, `labelOf(...)`, and the empty-parse stub `noMessages` (`:45-47`) — use those, not `SyncRunnerTests`' `tmp(_:ext:)`.

`FixedLabels` from Task 3 is `private` to `SalienceClassifierTests.swift`, so add a file-private copy here. Task 3 Step 7 converts this file's existing `DropSet`/`AlwaysThrows` stubs to the new method; `AlwaysThrows` must be **converted, not deleted**, because `suggesterWritesNothingWhenProviderFails` (`:66-74`) is the spec's write-nothing-on-failure test and must keep passing.

```swift
private struct FixedLabels: LLMProvider {
  let labels: [Int: String]
  func complete(prompt: String) async throws -> String { "[]" }
  func classifySalienceLabels(prompt: String) async throws -> [Int: String] { labels }
}

@Test func windowExcludesLooseEndsOlderThanTheCutoff() async throws {
  let database = try openCanonicalDatabase(at: tempURL("sug-window"))
  let now = Date()
  let (recentID, _) = try seedLE(database, quote: "recent one", createdAt: now)
  let (oldID, _) = try seedLE(database, quote: "old backlog one",
                              createdAt: now.addingTimeInterval(-30 * 86_400))

  let provider = FixedLabels(labels: [0: LooseEndLabel.salient])
  _ = try await SalienceSuggester(provider: provider, parse: noMessages)
    .run(database, limit: nil, force: false, createdAfter: now.addingTimeInterval(-7 * 86_400))

  #expect(try labelOf(database, recentID).suggestion == LooseEndLabel.salient)
  #expect(try labelOf(database, oldID).suggestion == "")   // the backlog is out of reach
}

@Test func nilWindowKeepsTheFullBacklogEligible() async throws {
  let database = try openCanonicalDatabase(at: tempURL("sug-nowindow"))
  let (oldID, _) = try seedLE(database, quote: "old backlog one",
                              createdAt: Date().addingTimeInterval(-30 * 86_400))

  let provider = FixedLabels(labels: [0: LooseEndLabel.salient])
  _ = try await SalienceSuggester(provider: provider, parse: noMessages)
    .run(database, limit: nil, force: false, createdAfter: nil)

  #expect(try labelOf(database, oldID).suggestion == LooseEndLabel.salient)
}

@Test func limitCapsHowManyAreSuggestedInOneRun() async throws {
  let database = try openCanonicalDatabase(at: tempURL("sug-cap"))
  let now = Date()
  for index in 0..<5 {
    _ = try seedLE(database, quote: "candidate \(index)",
                   createdAt: now.addingTimeInterval(TimeInterval(index)))
  }

  let provider = FixedLabels(labels: [0: LooseEndLabel.salient])
  let summary = try await SalienceSuggester(provider: provider, parse: noMessages)
    .run(database, limit: 2, force: false, createdAfter: now.addingTimeInterval(-86_400))

  // The cap is what stops one sync cycle becoming an hour of `claude -p` calls, so it has to hold
  // when a window is also in play — both filters apply, neither replaces the other.
  #expect(summary.candidates == 2)
  #expect(summary.suggested == 2)
  let suggestedCount = try database.read { database in
    try LooseEnd.where { $0.labelSuggestion.neq("") }.fetchCount(database)
  }
  #expect(suggestedCount == 2)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
make test FILTER=window
```

Expected: FAIL — `extra argument 'createdAfter' in call`.

- [ ] **Step 3: Implement the window**

In `Sources/PensieveKit/Intelligence/SalienceSuggester.swift`, change the signature and the candidate query:

```swift
  /// - Parameter createdAfter: when non-nil, only loose ends created at or after this instant are
  ///   candidates. The sync path passes a lookback window so the daemon can never walk the
  ///   pre-existing backlog unattended; `nil` (the CLI backfill) keeps every unlabeled end
  ///   eligible. A window rather than "created this cycle" so a batch that failed on a provider
  ///   error stays a candidate on the next several cycles.
  public func run(_ database: any DatabaseWriter, limit: Int?, force: Bool,
                  createdAfter: Date? = nil) async throws -> Summary {
    let candidates: [LooseEnd] = try await database.read { database in
      let rows = try LooseEnd.where { $0.label.eq(LooseEndLabel.unlabeled) }.fetchAll(database)
      return rows.filter { force || $0.labelSuggestion.isEmpty }
                 .filter { createdAfter.map { cutoff in $0.createdAt >= cutoff } ?? true }
                 .sorted { $0.createdAt < $1.createdAt }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
make test FILTER=window && make test FILTER=Suggester
```

Expected: PASS, and the pre-existing suggester tests still pass (they omit `createdAfter`, which defaults to `nil`).

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add Sources/PensieveKit/Intelligence/SalienceSuggester.swift \
        Tests/PensieveKitTests/SalienceSuggesterTests.swift
git commit -m "feat: bound salience suggestion to a lookback window"
```

---

### Task 7: The sync-path salience pass

**Files:**
- Modify: `Sources/PensieveKit/Sync/SyncRunner.swift`
- Modify: `Sources/pensieve/Commands/Sync.swift:10-16`
- Modify: `Sources/PensieveSyncAgent/PensieveSyncAgent.swift:17-23`
- Test: `Tests/PensieveKitTests/SyncRunnerTests.swift`

**Interfaces:**
- Consumes: `SalienceSuggester.run(_:limit:force:createdAfter:)` (Task 6).
- Produces: `SyncRunner.init(..., salienceProvider: (any LLMProvider)? = nil)` and `SyncRunner.Summary.suggested: Int`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PensieveKitTests/SyncRunnerTests.swift`:

```swift
private struct CountingLabels: LLMProvider {
  let counter: Counter
  func complete(prompt: String) async throws -> String { "[]" }
  func classifySalienceLabels(prompt: String) async throws -> [Int: String] {
    await counter.bump()
    return [0: LooseEndLabel.salient]
  }
}
private actor Counter {
  private(set) var calls = 0
  func bump() { calls += 1 }
}

@Test func syncSkipsSalienceWhenNoProviderIsInjected() async throws {
  let projects = tmp("projects-nosal", ext: "d")
  try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
  try writeSession(projects, UUID().uuidString, prompts: 1)
  let spool = try CaptureSpool(at: tmp("nosal-spool", ext: "sqlite"))
  let database = try openCanonicalDatabase(at: tmp("nosal-canon", ext: "sqlite"))

  let summary = try await SyncRunner(spool: spool, database: database, provider: NoopProvider(),
                                     projectsDir: projects, now: { Date() }).run()
  #expect(summary.suggested == 0)
}

@Test func syncSuggestsForRecentLooseEndsWhenAProviderIsInjected() async throws {
  let projects = tmp("projects-sal", ext: "d")
  try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
  let spool = try CaptureSpool(at: tmp("sal-spool", ext: "sqlite"))
  let database = try openCanonicalDatabase(at: tmp("sal-canon", ext: "sqlite"))

  // A recent unlabeled loose end, and one older than the lookback window.
  let node = Node(name: "N")
  let source = Source(nodeID: node.id, kind: SourceKind.claudeCode, key: "/src/\(UUID().uuidString)")
  let event = Event(nodeID: node.id, sourceID: source.id, occurredAt: Date(),
                    kind: CaptureKind.ccSession, summary: "s", detailJSON: "{}")
  let recent = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t", quote: "q",
                        createdAt: Date())
  let ancient = LooseEnd(nodeID: node.id, sourceEventID: event.id, text: "t2", quote: "q2",
                         createdAt: Date().addingTimeInterval(-90 * 86_400))
  try database.write { database in
    try Node.insert { node }.execute(database)
    try Source.insert { source }.execute(database)
    try Event.insert { event }.execute(database)
    try LooseEnd.insert { recent }.execute(database)
    try LooseEnd.insert { ancient }.execute(database)
  }

  let counter = Counter()
  let summary = try await SyncRunner(spool: spool, database: database, provider: NoopProvider(),
                                     projectsDir: projects, now: { Date() },
                                     salienceProvider: CountingLabels(counter: counter)).run()

  #expect(summary.suggested == 1)
  let rows = try database.read { database in try LooseEnd.all.fetchAll(database) }
  #expect(rows.first { $0.id == recent.id }?.labelSuggestion == LooseEndLabel.salient)
  #expect(rows.first { $0.id == ancient.id }?.labelSuggestion == "")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
make test FILTER=Salience
```

Expected: FAIL — `extra argument 'salienceProvider' in call`.

- [ ] **Step 3: Add the pass to `SyncRunner`**

In `Sources/PensieveKit/Sync/SyncRunner.swift`, add the stored property, the init parameter (last, defaulted `nil`), the tuning constants, and the `suggested` field:

```swift
  let salienceProvider: (any LLMProvider)?

  /// How far back the sync pass looks for unlabeled loose ends. Bounded so the daemon can never
  /// walk the pre-existing backlog unattended — that stays `pensieve label-suggest`, run by a
  /// person. Long enough that a batch failing on a provider error is retried for several days.
  static let salienceLookback: TimeInterval = 7 * 86_400
  /// Per-cycle item cap, so one sync cycle cannot become an hour of `claude -p` calls.
  static let salienceCap = 50
```

Add `salienceProvider: (any LLMProvider)? = nil` as the final `init` parameter and assign it. Add `public let suggested: Int` to `Summary`.

Then, in `run()`, **after** the `searchIndexer` calls and before `return`:

```swift
    // Advisory salience labelling. Deliberately LAST: it is the only stage that can spend two
    // minutes in a `claude -p` call, and search freshness — which the app's ⌘F depends on — must
    // not queue behind it. Best-effort throughout: a failure logs and returns 0 rather than
    // failing the cycle, because a sync that ingested work must not be reported as failed
    // because an optional label did not get written.
    var suggested = 0
    if let salienceProvider {
      do {
        let result = try await SalienceSuggester(provider: salienceProvider).run(
          database, limit: Self.salienceCap, force: false,
          createdAfter: now().addingTimeInterval(-Self.salienceLookback))
        suggested = result.suggested
        Log.sync.info("""
          Salience: suggested=\(result.suggested, privacy: .public) \
          salient=\(result.salient, privacy: .public) noise=\(result.noise, privacy: .public) \
          unsure=\(result.unsure, privacy: .public) skipped=\(result.skipped, privacy: .public)
          """)
      } catch {
        Log.sync.error("Salience pass failed: \(error, privacy: .public)")
      }
    }

    return Summary(ingested: ingested, discovered: discovered.count, extracted: extracted,
                   suggested: suggested)
```

Update the existing `return Summary(...)` call to the four-argument form, and add `suggested=\(suggested…)` to the "Sync complete" log line.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
make test FILTER=Salience && make test FILTER=sync
```

Expected: PASS. The pre-existing `SyncRunner` tests omit `salienceProvider`, so they exercise the nil path.

- [ ] **Step 5: Inject the Haiku provider at both production entry points**

`SyncRunner`'s main `provider` is `makeDefaultLLMProvider` — on-device Foundation Models, which measured recall 0.68 on this task. The salience pass needs Haiku, exactly as `pensieve label-suggest` already does.

The model-pinned `claude -p` runner currently lives as `LabelSuggest.claudeRun` (`Sources/pensieve/Commands/LabelSuggest.swift:57-84`), which `PensieveSyncAgent` cannot reach. `ClaudeCLIProvider.shellRun` cannot be reused as-is because it hardcodes `["claude", "-p"]` with no `--model`.

> **⚠️ This step must fix a latent bug while moving the helper, or it creates a feedback loop.**
> `LabelSuggest.claudeRun` does **not** set `process.currentDirectoryURL`. Under the CLI that is
> harmless — cwd is wherever you ran it. Under the launchd agent, **cwd is `/`**, and
> `ClaudeCLIProvider.shellRun`'s own comment documents exactly what that causes: every `claude -p`
> call becomes a Claude Code session at the filesystem root, gets captured by the `SessionEnd`
> hook, and is re-ingested as work — a feedback loop that previously produced a phantom project
> named `/`. Moving this helper onto the daemon path without pinning cwd walks straight back into
> it. Pin it to `PensievePaths.llmScratchDirectory()`, as `shellRun` does.

Move the helper into `Sources/PensieveKit/LLM/ClaudeCLIProvider.swift` as a model-taking sibling of `shellRun`, and add the factory:

```swift
public extension ClaudeCLIProvider {
  /// The salience provider: `claude -p` pinned to Haiku. Separate from `SyncRunner`'s main
  /// provider on measured grounds — on-device Foundation Models scored recall 0.68 on this task
  /// (`docs/superpowers/salience-eval-2026-07-09.md`) and must not be used for it.
  static func haiku(model: String = "claude-haiku-4-5-20251001") -> ClaudeCLIProvider {
    ClaudeCLIProvider(run: { try shellRun($0, model: model) })
  }
}
```

Give `shellRun` a `model: String? = nil` parameter rather than duplicating its body: it already has the correct concurrent stdin/stdout/stderr draining, the 120 s timeout, **and the cwd pin**. `nil` keeps today's `["claude", "-p"]` arguments byte-identical so every existing caller is unaffected; a non-nil model appends `["--model", model]`.

Then in `Sources/pensieve/Commands/Sync.swift` and `Sources/PensieveSyncAgent/PensieveSyncAgent.swift`, add to each `SyncRunner(...)` construction:

```swift
        salienceProvider: ClaudeCLIProvider.haiku(),
```

Finally, delete `LabelSuggest.claudeRun` and `LabelSuggest.timeout`, and change `LabelSuggest.run` to `let provider = ClaudeCLIProvider.haiku(model: model)` — the `--model` option keeps working, and the CLI silently gains the cwd pin it was missing. `SalienceEvalTests` has its own private `claudeRun` copy; leave it alone (a test helper pinning cwd would change what the eval measures for no benefit).

- [ ] **Step 6: Verify the daemon can actually reach `claude -p`**

This is the risk spec § 3.2 names, and it must be checked before the pass is trusted. `launchd` does no `~` expansion, which is why `SyncAgentEnvironment.resolvedPATH` exists.

```bash
make cli
PENSIEVE_DB=/tmp/salience-smoke.sqlite \
PENSIEVE_CAPTURE_DB=/tmp/salience-smoke-capture.sqlite \
  ./.build-xcode/Build/Products/Debug/Pensieve.app/Contents/Helpers/pensieve sync
/usr/bin/log show --predicate 'subsystem == "me.mazetti.pensieve" AND category == "sync"' \
  --last 5m --style compact | grep -i salience
```

Expected: a `Salience: suggested=0 …` line (the temp store has no loose ends). A `Salience pass failed:` line means the provider could not run.

Then the real check — after `make install`, watch one scheduled agent cycle:

```bash
tail -f ~/Library/Logs/Pensieve/sync.log
```

If `claude -p` cannot authenticate from launchd, **stop and report**. The pre-specified fallback is to pass `nil` in `PensieveSyncAgent` only, leaving `pensieve sync` and `label-suggest` working — suggestion stays CLI-driven, which is a worse outcome but an honest one. Record whichever happened in the measurement README.

- [ ] **Step 7: Lint and commit**

```bash
make lint && make all
git add -A Sources Tests
git commit -m "feat: label recent loose ends from the sync path (advisory, never deletes)"
```

---

### Task 8: Fork the shared comparator

**Files:**
- Modify: `Sources/PensieveKit/Query/LooseEndQueries.swift:36-58`
- Test: `Tests/PensieveKitTests/SalienceReviewQueriesTests.swift`

**Interfaces:**
- Produces: `LooseEndQueries.oldestFirst(_:_:) -> Bool` alongside the existing `suggestedSalientFirstThenOldest`.

**Why:** one comparator now serves two feeds that need opposite behaviour. `SalienceReviewQueries.pending` (the audit queue) should lead with suggested-salient — that is its purpose. `LooseEndQueries.openAcrossNodes` (the burn-down queue) must not be reordered by unaudited guesses, which is what Task 7 is about to start producing. The existing doc comment warns that a *copy* is how two orderings drift; the fix is two named comparators with stated reasons, not one function serving neither.

- [ ] **Step 1: Write the failing test**

Append to `Tests/PensieveKitTests/SalienceReviewQueriesTests.swift`. It already has everything needed: a file-private `seed(_:quote:label:suggestion:status:daysAgo:) -> UUID` (`:6-23`) and `tempURL(_:)`. Each `seed` call creates its own `Node`, so `openAcrossNodes` needs every node id as its visible set.

Only **one** new test is needed. The audit queue's ordering is already pinned by the existing `reviewPendingOrdersSuggestedSalientFirst` (`:39-46`) — that test must keep passing unchanged, which is what proves the fork did not break the feed that *wants* salient-first.

```swift
@Test func burnDownQueueIgnoresSuggestionsAndSortsOldestFirst() throws {
  let database = try openCanonicalDatabase(at: tempURL("burndown-order"))
  // An OLD end with no suggestion, and a NEWER one a machine guessed is salient. Ordering must
  // follow age: an unaudited guess does not get to jump the burn-down queue.
  let older = try seed(database, quote: "older, unsuggested", label: "", suggestion: "", daysAgo: 10)
  let newer = try seed(database, quote: "newer, suggested salient", label: "",
                       suggestion: LooseEndLabel.salient, daysAgo: 1)

  let visible = try database.read { database in
    Set(try Node.all.fetchAll(database).map(\.id))
  }
  let views = try LooseEndQueries.openAcrossNodes(database, visibleNodeIDs: visible, now: Date())
  #expect(views.map(\.looseEnd.id) == [older, newer])
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
make test FILTER=burnDownQueue
```

Expected: FAIL — `openAcrossNodes` currently promotes the suggested-salient row, so the order comes back as `[newer, older]`.

This failure is the whole justification for the task: it is the shipped behaviour Task 7 is about to start triggering for real.

- [ ] **Step 3: Fork the comparator**

In `Sources/PensieveKit/Query/LooseEndQueries.swift`, change `openAcrossNodes` to sort by a new comparator and rewrite both doc comments:

```swift
  public static func openAcrossNodes(_ database: any DatabaseReader, visibleNodeIDs: Set<UUID>,
                                     now: Date) throws -> [LooseEndView] {
    try openViews(database, visibleNodeIDs: visibleNodeIDs, now: now)
      .sorted(by: oldestFirst)
  }

  /// The burn-down queue's ordering. Deliberately does NOT read `labelSuggestion`: suggestions are
  /// unaudited machine guesses, and at the precision measured in
  /// `docs/superpowers/measurements/2026-08-15-salience-prompt/` promoting on them is worse than
  /// age. A suggestion earns a tier here only once the pre-registered bar in
  /// `docs/superpowers/specs/2026-08-15-salience-prompt-and-advisory-labelling-design.md` § 4 is
  /// cleared — precision >= 0.50 and recall >= 0.70 on the held-out set.
  static func oldestFirst(_ left: LooseEndView, _ right: LooseEndView) -> Bool {
    left.occurredAt < right.occurredAt
  }

  /// The AUDIT queue's ordering — `SalienceReviewQueries.pending` only. Leading with suggested-
  /// salient is the entire point there: it harvests the scarce positives for review, and a wrong
  /// guess costs one audit slot rather than a misordered backlog. This split from `oldestFirst`
  /// is deliberate; the two feeds want opposite things and a single shared comparator served
  /// neither.
  static func suggestedSalientFirstThenOldest(_ left: LooseEndView, _ right: LooseEndView) -> Bool {
```

Leave `suggestedSalientFirstThenOldest`'s body unchanged, and delete the now-false "Measured 2026-08-15: the salient tier is currently inert" paragraph — Task 7 makes it untrue.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
make test FILTER=burnDownQueue && make test FILTER=reviewPending && make test
```

Expected: PASS, **including `reviewPendingOrdersSuggestedSalientFirst` and `reviewPendingReturnsUnlabeledSuggestedRegardlessOfStatus` unchanged** — the audit queue keeps its salient-first ordering, which is what makes this a fork rather than a removal. Watch for other pre-existing tests that asserted the old `openAcrossNodes` ordering; if one fails, it was pinning behaviour this task intentionally changes — update it and say so in the commit message.

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add Sources/PensieveKit/Query/LooseEndQueries.swift \
        Tests/PensieveKitTests/SalienceReviewQueriesTests.swift
git commit -m "fix: keep unaudited suggestions out of the burn-down queue's ordering"
```

---

### Task 9: Record outcomes, exceptions, and the defect found on the way

**Files:**
- Modify: `Tests/PensieveKitTests/Fixtures/salience-labels.README.md`
- Modify: `docs/superpowers/backlog.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Correct the stale fixture README**

`Tests/PensieveKitTests/Fixtures/salience-labels.README.md` still instructs the reader to build a gold set that has existed since July. Rewrite it to say: this file is a 10-quote synthetic compile seed; the real dev and test sets live at `~/Library/Application Support/Pensieve/salience-corpus/` (95 and 120 items); point the harness with `PENSIEVE_SALIENCE_LABELS`; the dev set is for iteration and the July set is held out. Delete the `.superpowers/sdd/task-A5-brief.md` reference — that path no longer exists.

- [ ] **Step 2: Update the backlog's salience entry**

In `docs/superpowers/backlog.md` § "The salience pipeline is built, wired, and has never been run", replace the *Status 2026-08-15* paragraph with the outcome: the dev/test split and why the 122 thumbs are not the gold set, the held-out numbers from Task 5, the gate decision, and the fact that suggestion now runs from the sync path over a 7-day window while the 986-row backfill stays manual. Keep finding **2** (the duplicated comparator) but mark it resolved by Task 8, noting the two comparators are now deliberately distinct rather than accidentally identical.

- [ ] **Step 3: Record the `EvalTask` exception under F4**

In backlog § "Naming has no eval coverage, and the harness has a silent hole", add salience to the list of model-backed tasks running without a registered `EvalTask`, with the reason: the model-choice question is answered empirically (on-device 0.68 vs Haiku 0.947 recall on a real hand-labelled set) and `SalienceEvalTests` computes precision/recall against that set, which for a single-prompt classifier is more reproducible than a rubric judge. Note that registering it needs a new scorer kind plus `CorpusBuilder` plumbing, and is blocked behind the guardrail hole F4 already documents.

- [ ] **Step 4: File the capture-attribution defect**

Add a new backlog entry: roughly a dozen of the 98 noise-labelled loose ends are teammate messages and agent status reports stored with `role: user` — `<teammate-message teammate_id="reviewer-1">`, `"Baseline still running"`, `"CHANGELOG auto-merged with both entries."` All 122 labelled ends carry `role: user`. No prompt can fix "the human did not write this"; it inflates the noise class and mildly deflates measured precision on both gold sets. Note the relevant context from `CLAUDE.md`: `isUserPrompt` is a bare `contains` and `SpeakerClass.of` is conjunctive on purpose, so any fix here is trust-gate-adjacent and needs its own spec. Give it a revisit trigger: the next extraction-quality question, or the next time a gold set is sampled.

- [ ] **Step 5: Add the `CLAUDE.md` status bullet**

Add a bullet in the Status list, in the established style: what shipped (gold set, prompt rewrite, advisory sync-path labelling, comparator fork), the measured numbers and the gate decision, the deliberate non-registration of an `EvalTask`, the trust gate being untouched, the final test count, and the spec/plan paths. State plainly if the gate was not cleared — that is the outcome, not a gap.

- [ ] **Step 6: Full verification and commit**

```bash
make all
```

Expected: lint clean, all tests pass, app builds, CLI smoke passes. Record the test count.

```bash
git add -A docs CLAUDE.md Tests/PensieveKitTests/Fixtures/salience-labels.README.md
git commit -m "docs: record the salience gold set, gate decision, and the role:user capture defect"
```

---

## Human verification carries

These need the built app, the real store, and a person:

- **Review Suggestions returns rows.** After one sync cycle with new loose ends, the sidebar's Review Suggestions bucket is non-empty and its badge count matches. It has been structurally empty since it shipped.
- **The burn-down queue did not change.** The Loose Ends bucket still reads oldest-first; a freshly suggested-salient item has not jumped the queue.
- **Audit a dozen suggestions by hand** and check the labels are the ones you would have given. The held-out number predicts this, but it is the first time you will see the prompt's output in situ.
- **One scheduled agent cycle writes a `Salience:` line** to `~/Library/Logs/Pensieve/sync.log` — the launchd `claude -p` question from Task 7 Step 6, confirmed on the real schedule rather than a hand-run.
