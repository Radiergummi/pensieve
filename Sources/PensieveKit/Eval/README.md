# `pensieve eval` — the LLM evaluation harness

Every capable feature that calls a model through `LLMProvider` (loose-end extraction,
narration, node description, ...) needs a real answer to "why this model, and not a
cheaper or more private one?" This harness gives that answer empirically: it runs a
candidate roster (on-device Foundation Models plus cloud models from OpenAI, xAI,
Google, Anthropic) over a frozen corpus for each registered task, scores outputs with an
objective grounding check (extraction) or a blinded rubric judge (soft tasks), and
recommends a default per task — filtered by an incumbent-anchored acceptance bar, then
ranked privacy/locality → cost → latency → quality. It never hand-picks a model; it
measures.

## Stage isolation

Real pipelines are multi-stage, and not every stage is the one under test. The harness
swaps the model **only at the stage being evaluated** and pins every other model-calling
stage to a **fixed reference provider** (on-device FM by default). For example, the
extraction task measures the candidate-generation call only — `IntentClassifier` and
`SessionSummarizer` still run on the fixed reference for every model under test. This
keeps "classifiers out of scope" honest and removes fail-open asymmetries (some
providers silently keep more input on a malformed response) from the numbers.

## Incumbent-anchored bars

Bars are not hand-picked constants. The harness first runs the currently-shipped
default (on-device FM) over the frozen corpus to measure its own precision/recall/
quality, then sets each task's acceptance bar to that measured incumbent performance.
"Clears the bar" means "no worse than what ships today"; "recommend a challenger" means
"measurably beats the incumbent by more than the run-to-run noise margin." A model must
clear the bar robustly — set `inheritFromIncumbent: true` on a task's `TaskBar` in
`eval-config.json` to have the harness compute the bar from the incumbent's own run
instead of a fixed number.

## Add a task in 3 steps

Worked example: adding the (already-shipped) **narration** task.

**1. Implement an `EvalTask`.** One file, one value type: an `id`, a `scorer`
(`.extraction` for objective grounding, or `.rubric(dimensions:)` for a judged soft
task), and a `run(item:model:reference:)` that drives the real component with the model
under test swapped in at the isolated stage only:

```swift
// Sources/PensieveKit/Eval/NarrationTask.swift
public struct NarrationTask: EvalTask {
  public init() {}
  public let id = "narration"
  public let scorer: ScorerKind = .rubric(dimensions: ["grounded", "complete", "concise", "noInventedFacts"])

  public func run(item: CorpusItem, model: any LLMProvider, reference: any LLMProvider) async throws -> TaskOutput {
    guard case .narration(let n) = item else { throw EvalTaskError(message: "narration task got non-narration item") }
    let node = Node(name: n.nodeName)
    let events = n.events.map { $0.toDomain() }
    let prose = await SummaryBuilder(provider: model).narrate(project: node, events: events)
    return TaskOutput(text: prose ?? "", looseEnds: nil)
  }
}
```

**2. Register it in `TaskRegistry.all`:**

```swift
// Sources/PensieveKit/Eval/EvalTask.swift
public static var all: [any EvalTask] { [ExtractionTask(), NarrationTask(), DescriptionTask()] }
```

**3. Add its acceptance bar to `eval-config.json`:**

```json
{ "task": "narration", "inheritFromIncumbent": true }
```

That's it — the runner, judge, scorecard, cost/latency capture, and reporting are all
task-agnostic and inherited from the protocol.

## The guardrail

`Tests/PensieveKitTests/EvalConfigConsistencyTests.swift` loads the committed
`eval-config.json` and asserts `TaskRegistry.consistencyProblems(config:).isEmpty` —
every registered `EvalTask` must have a bar, and every bar must have a registered task.
Add a task without step 3 (or typo the `task` id) and this test fails the suite, so a
new LLM-backed feature can't silently ship a hand-picked default.
