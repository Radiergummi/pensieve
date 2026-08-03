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

Every loose end Pensieve shows me cites real captured text (say, a verbatim quote from a transcript or commit) or it does not appear at all. This is enforced by a trust gate in the extraction path, and it is the core provenance grounding constraint. A tool that reminds me of things I never said is worse than no tool, because I'd have to verify everything it tells me, and then I'm doing the work again.  
LLM-written prose (the "last work done" recap, strand naming) sits deliberately *outside* that gate, and is best-effort: when the model has nothing grounded to say, the code returns *nothing* rather than a plausible summary. There is no fallback that invents.

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

## Surfaces

- The app itself, a three-pane SwiftUI window: a briefing home, smart lists (What's Next / Dormant / Recently Active), the typed node tree, and a recall view showing what a node is, its open loose ends with inline verbatim provenance, and its recent activity. Plus a menu-bar item, `pensieve://` deep links, a provenance inspector, secondary recall windows, macOS Focus filters (work vs. personal), Spotlight and App Intents integration, and ⌘F search across both exact and semantic recall. Localized in English and German.
- The `pensieve` CLI , bundled inside the app at `Contents/Helpers/pensieve` and symlinked to `~/.local/bin`. Commands for capture (`capture-commit`, `capture-session-start`), ingestion (`ingest`, `sync`), organizing (`add-node`, `nest`, `rename`, `retype`, `group`), and querying (`list`, `status`, `next`, `digest`, `looseends`).
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
