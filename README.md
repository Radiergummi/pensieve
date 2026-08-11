<img src="icons/Pensieve-macOS-Default-1024@1x.png" alt="" width="128" align="left" hspace="16" vspace="4">

# Pensieve

**A personal macOS tool that reconstructs where each of my parallel projects stands.**
It captures my git commits and Claude Code sessions automatically, then surfaces grounded, provenance-cited summaries and a "what's next" queue.

<br clear="left">

---

> [!IMPORTANT]
> **What this is**  
> Pensieve is an app I've written for myself and my way of working. It was not inteded to becoming a product, or an open source project. For now, there is no [license](#license), no changelog, and no public roadmap, and I won't offer support for running it beyond what this Readme provides.  
> Also note that it will probably not work cleanly on your machine, since Pensieve hardcodes some assumptions about my setup: An ad-hoc code-signing identity, the app installed at `/Applications/Pensieve.app`, `~/.local/bin` on `PATH`, and my Claude Code configuration.  
> Read it, learn from it, steal ideas from it. Just don't expect a project.

## The problem

I run many efforts in parallel - side projects, work threads, half-finished experiments. The expensive part is never the work itself. It's the reload: Coming back to something after two weeks and spending an hour reconstructing what I'd decided, what I'd half-finished, and what the next move was.

I have ADHD. That reload cost is not a mild annoyance; it's the thing that kills projects. Notes don't help, because keeping them current is itself the task I can't reliably do.

So Pensieve doesn't ask me to write anything. It watches what I already do, like committing code, talking to Claude Code, and so on, and reconstructs the state of each effort from that.

## What it does

- **Captures, automatically.** Git hooks record commits. Claude Code `SessionStart`/`SessionEnd` hooks record sessions, and a background agent ingests the transcripts. I never type anything into Pensieve to keep it current.
- **Organizes into a tree of work.** A project is an area of work, not a directory. Git repos are one *source type*; Claude Code sessions are another. Many sources bind to one node, and nodes nest into a typed tree. Long-running sub-efforts ("strands") get born automatically when the same kind of activity recurs.
- **Surfaces loose ends.** The thing I actually need: the open threads I left behind. "You said you'd investigate sqlite-vec." "You decided to defer the fork backend." Each one cites the exact sentence it came from.
- **Answers "where was I?"** A briefing of what changed since I last looked, per project, plus a ranked queue of what to pick up next.
- **Explains what a thing even is.** A node's description is derived from the repo itself, not from me writing one. Checkpoints are the one place I *can* type a note, when I want to leave myself something the capture path could never infer.

Every loose end Pensieve shows me cites real captured text (say, a verbatim quote from a transcript or commit) or it does not appear at all. This is enforced by a trust gate in the extraction path, and it is the core provenance grounding constraint. A tool that reminds me of things I never said is worse than no tool, because I'd have to verify everything it tells me, and then I'm doing the work again.  
LLM-written prose (the "last work done" recap, strand naming) sits deliberately *outside* that gate, and is best-effort: when the model has nothing grounded to say, the code returns *nothing* rather than a plausible summary. There is no fallback that invents.

## How a loose end is made

Mining open threads out of a coding-agent transcript is mostly a precision problem. A session is thousands of lines of me pasting specs, agents printing plans, and tool output scrolling past; the few sentences where I actually deferred something are buried in it. So extraction is a funnel of cheap deterministic filters bracketing the expensive semantic ones:

```
session transcript
  │
  ├─ isUserPrompt            pure    user-authored turns only
  ├─ StructuralNoiseFilter   pure    drop generated agent briefs (long AND templated)
  ├─ IntentClassifier        model   keep only messages that are my own intent
  ├─ LooseEndExtractor       model   propose candidates: a summary + a supporting quote
  ├─ CandidateFilter         pure    drop closures, status checks, pasted tool output
  ├─ LooseEndVerifier        pure    ── THE TRUST GATE ── quote must be verbatim, long
  │                                     enough, and from a real user-authored message
  └─ stored loose end
```

`IntentClassifier` is the one stage that has to be a model. A spec I pasted is recorded as a `promptSource: typed` user message exactly like a sentence I typed myself, so the transcript's own metadata cannot separate "what I meant" from "what I pasted" - that is irreducibly a semantic judgment. Everything else on either side of the extractor is a pure, tested function.

Two properties of the arrangement matter more than any single stage:

**The gate is last, and it can only subtract.** The one stage that can *introduce* text (`LooseEndExtractor`) is immediately followed by the verbatim check, and nothing model-driven runs after it. A loose end that reaches storage has been checked, character for character, against a message I actually wrote.

**Failure direction.** Every model stage fails toward the outcome I can live with. `IntentClassifier` fails *open* on a hard provider error, so a transient glitch degrades precision rather than silently zeroing out a session's extraction entirely. Being shown one request I'd already handled costs me a second; not being shown the thing I parked two weeks ago costs me the project.

### The classifier that didn't ship

There is a second classifier in the tree - `SalienceClassifier` - and it is **deliberately not wired into extraction**. It was built to solve a real remaining problem: A quote can be perfectly verbatim and still not be a loose end, because "read the spec, then fix the test" is a request the assistant carried out three seconds later, not an open thread waiting for me.

Then I hand-labeled 120 real quotes from my own store (19 genuinely salient, 101 not) and measured it. The on-device ~3B model scored **recall 0.68** - it confidently discarded six genuine loose ends while removing little noise. Haiku did far better on recall (0.947) but its precision was still only 0.23, and it is non-deterministic.

So the gate stays off and extraction stays lossless. For a tool whose entire premise is "never lose the thing you parked," a filter that silently eats a third of the real ones is worse than no filter, and modest precision is not worth buying with it. The code remains, exercised by the eval harness and by `pensieve label-suggest`, which runs the same classification offline over the stored backlog and writes a *suggestion* column only, never my own labels - accumulating the labeled corpus a deterministic on-device replacement will need. The write-up is [`docs/superpowers/salience-eval-2026-07-09.md`](docs/superpowers/salience-eval-2026-07-09.md).

## How it works

Pensieve uses three SQLite databases, which are deliberately kept separate:

```
git hook / CLI ──► capture.sqlite ──► Ingester.drain() ──► pensieve.sqlite ──► queries
                   (dumb spool)                            (canonical store)
```

The capture spool is append-only, WAL, and never synced. A git hook writes one raw row and exits. The capture path is sacred: It must be fast, fire-and-forget, and never block or break a commit. If Pensieve is broken, my commits still work.  
The canonical store is the rich model, and `Ingester.drain()` is its only writer. Ingestion enriches raw rows into project-attributed events: It shells out to `git show` for commits, and reads the on-disk `.jsonl` transcripts for Claude Code sessions. Everything else in the system reads this store read-only.  
A separate, rebuildable, never-synced `semantic-index.sqlite` holds vector embeddings (using `NLContextualEmbedding` and `sqlite-vec`) for semantic recall. It is disposable by design; delete it and it rebuilds automatically.

Attribution runs by canonicalized filesystem path/source/node, keyed on the git *common* directory so worktrees of one repo unify into a single node.

## Choosing the models

Every feature that calls a model needs an answer to "why *this* model, and not a cheaper or more private one?" Hand-picking a constant and moving on is how that question stays permanently unanswered, so `pensieve eval` answers it empirically instead: It sweeps a candidate roster (on-device Foundation Models plus cloud models from Anthropic, OpenAI, Google and xAI) over a frozen corpus for each registered task, and recommends a default. Extraction is scored objectively, by checking grounding; the soft tasks (narration, node description) go to a blinded rubric judge.

Three things keep the numbers honest:

- **Stage isolation.** A real pipeline is multi-stage, and only one stage is under test. The harness swaps the candidate model *only* at that stage and pins every other model-calling stage to a fixed reference provider. Evaluating extraction measures the candidate-generation call alone - the classifiers around it run on the reference for every model tested, so fail-open differences between providers can't leak into the score.
- **Incumbent-anchored bars.** Acceptance thresholds aren't hand-chosen constants either. The harness first measures the currently-shipped default over the same frozen corpus, then sets the bar to *that*. "Clears the bar" means "no worse than what ships today"; recommending a challenger means it beat the incumbent by more than the run-to-run noise margin.
- **Ranking by what I actually care about**, in order: privacy/locality, then cost, then latency, then quality. On-device wins ties by construction, which is why extraction has stayed local.

A test fails the suite if a registered task has no configured default, so a new model-backed feature can't quietly ship a guess.

The harness earns its keep mostly by *stopping* things. The salience gate above was already written, already merged, and felt right; it took a measurement to establish it was quietly making the tool worse.

## Surfaces

- The app itself, a three-pane SwiftUI window: a briefing home, smart lists (What's Next / Dormant / Recently Active), the typed node tree, and a recall view showing what a node is, its open loose ends with inline verbatim provenance, and its recent activity. Plus a menu-bar item, `pensieve://` deep links, a provenance inspector, secondary recall windows, macOS Focus filters (work vs. personal), Spotlight and App Intents integration, ⌥⌘F search across the captured corpus and ⌘F find-within-a-project. Localized in English and German.
- The `pensieve` CLI , bundled inside the app at `Contents/Helpers/pensieve` and symlinked to `~/.local/bin`. Commands for capture (`capture-commit`, `capture-checkout`, `capture-session-start`/`-end`), ingestion (`ingest`, `sync`), source discovery and wiring (`scan`, `track`, `install-hooks`, `install-session-hook`), organizing (`add-node`, `nest`, `rename`, `retype`, `group`), querying (`list`, `status`, `next`, `digest`, `looseends`, `checkpoint`), and the model plumbing (`eval`, `label-suggest`).
- The MCP server (`pensieve mcp`) feeds Pensieve's grounded context *back into* Claude Code, with tools for project context, what's next, search, and `recall` (which returns the surrounding transcript window for a loose end, not just a pointer to it). `pensieve prime` runs as a `SessionStart` hook so a new session starts already knowing where the project stands.
- Intelligence runs on-device by default via Foundation Models. A cloud provider (Anthropic or OpenAI-compatible) is available for narration only, with the API key stored in the Keychain and never on disk. Extraction (the trust-gated part) is always on-device.

## Building it

**Requirements:** macOS 15+, Xcode 26.6, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (2.45+).

The framework and its tests are SwiftPM; the app and CLI are Xcode targets.

```sh
# Tests — 524 tests across 5 suites
./scripts/test.sh
./scripts/test.sh --filter projectRoundTrips

# Generate the Xcode project (project.yml is the source of truth)
xcodegen generate

# Build the app (this also builds and embeds the CLI)
xcodebuild -project Pensieve.xcodeproj -scheme Pensieve \
  -configuration Debug -derivedDataPath ./.build-xcode build
```

The bundle lands at `./.build-xcode/Build/Products/Debug/Pensieve.app`.

A fresh machine's first `xcodebuild` fails until the SwiftPM macro plugins are trusted — either click **Trust & Enable** when Xcode prompts, or run once:

```sh
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
```

**Wiring it up**, once the app is at `/Applications/Pensieve.app`:

```sh
pensieve scan ~/Projects --recursive --accept   # discover git repos, install hooks
pensieve install-session-hook                   # Claude Code SessionStart/SessionEnd
claude mcp add pensieve -- pensieve mcp         # expose context back to Claude Code
```

Background sync runs from a code-signed `SMAppService` agent bundled inside the app (approve once in System Settings ▸ General ▸ Login Items). The app must live at `/Applications/Pensieve.app`: `SMAppService` pins registration to path and cdhash, so a DerivedData path won't hold.

The `/Applications` home matters more than it looks: Each ad-hoc rebuild mints a new cdhash, and a bare `register()` silently no-ops a stale registration. The app does `unregister()` and `register()` to refresh it.

Logs: `tail -f ~/Library/Logs/Pensieve/sync.log`, or `log stream --predicate 'subsystem == "me.mazetti.pensieve"' --level debug`.

## License

**None.** No `LICENSE` file, which means default copyright: All rights reserved.
