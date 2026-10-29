# Pensieve

Personal, single-user macOS tool. Not a product.

- Do not add status, changelogs or branch outcomes here. They go in `docs/superpowers/backlog.md` or the branch's spec/plan.
- Design-first: spec + plan under `docs/superpowers/` before building a feature.

## Running it

- Use the `make` targets (`make` lists them). `make all` is what CI checks.
- Launch the app with `make run`, never Spotlight: every worktree build registers another bundle under the same id, and a stale copy looks like a regression.
- `make uitest` steals focus for ~35 s; it is not part of `make all`. See the `verify-app-ui` skill.
- The app has no unit tests. Do not "smoke-launch the inner binary" to verify app behaviour: it never renders a view, so `AppModel.start()` never runs. Keep logic in PensieveKit (tested); keep views thin.
- xcodebuild rewrites `Package.resolved`; discard that churn, do not commit it.
- `log` is shadowed by a shell builtin here: use `/usr/bin/log`. Recipes in `docs/observability.md`.
- SwiftSyntax/macro linker error on build: `rm -rf .build` and retry.
- This machine dogfoods it: real stores in `~/Library/Application Support/Pensieve/`; `~/.local/bin/pensieve` is a symlink into `/Applications/Pensieve.app` and is what git hooks, `~/.claude/settings.json` and `claude mcp add` call.

## Invariants

- The capture path (git hook → spool) must be fast, fire-and-forget, and never block or break a git commit.
- `Ingester.drain()` is the only writer of the canonical store. The app only reads.
- A project is an area of work, not a directory. Sources bind many-to-one to a node.
- BM25 over FTS5 is the only retrieval path. A vector engine was built, measured worse, and removed; do not bring it back.
- No API key, only a Claude subscription: LLM calls go through `LLMProvider` (default shells out to `claude -p`).
- New LLM-backed tasks register an `EvalTask` and take their default model from `pensieve eval`, not a hand-picked constant (`Sources/PensieveKit/Eval/README.md`).
- Focus filters, Widgets and CloudKit are blocked on a paid Apple Developer team (App Groups). Ad-hoc signing is on purpose.

## Lessons

- Two code paths that must agree will drift. Put the shared rule in one place (see `SearchHitResolver`, `FindMatcher`).
- Vacuous tests have shipped twice. Mutation-check new tests: delete the clause under test and watch the test go red.
- Prefer the OS-native mechanism (SwiftUI scenes, `.commands`, `WindowGroup` restoration) over a custom one; say why if you can't.
