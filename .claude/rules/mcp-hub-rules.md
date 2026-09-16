# MCP-Hub House Rules

Apply to every task in this distribution unless explicitly overridden. Bias: caution over
speed on non-trivial work; use judgment on trivial tasks. Loaded automatically at launch
(same priority as `CLAUDE.md`). Subagents get their discipline from the skills force-loaded
via `briefing.skills` — this file is for the orchestrating agent.

## Engineering discipline

1. **Think before coding** — state assumptions; when uncertain, ask rather than guess.
   Push back when a simpler approach exists.
2. **Simplicity first** — minimum code that solves the problem. Nothing speculative.
3. **Surgical changes** — touch only what you must. Match existing style.
4. **Goal-driven execution** — define success criteria, loop until verified.
5. **Surface conflicts, don't average them** — pick one (more recent / more tested), flag
   the other for cleanup. Don't blend.
6. **Read before you write** — the façade is one mechanism across three files
   (`Facade`, `Facade::Tool`, `Facade::Server`); the lifecycle is `Upstream` plus its
   three subclasses. Read the whole seam before changing any one file.
7. **Tests verify intent, not just behavior** — a test that can't fail when the logic
   changes is wrong. Reproduce a bug before fixing it; leave a regression test behind.
8. **Checkpoint after every significant step** — summarize: done / verified / left.
9. **Match conventions** — conformance > taste. Surface a harmful convention; don't fork.
10. **Fail loud** — "Done" is wrong if anything was skipped. "Tests pass" is wrong if any
    were skipped. Surface uncertainty.
11. **A red test is a claim before it is a failure** — before turning a test green, say
    what it asserts. Satisfying the assertion by removing the property it sampled proves
    nothing. If the claim is wrong, fix the claim and say so.

## Delegation

This rule depends on whether the Agent/Task tool is available to you.

- **You can spawn subagents** (orchestrating main agent): Do NOT touch behavior-relevant
  MCP-Hub code yourself — delegate to `mcp-hub-worker` (or `mcp-hub-test-writer` for test
  mechanics, `mcp-hub-release-checker` for a release audit). Your lane: coordinate,
  inspect, plan, review diffs, run tests, manage git, edit non-behavioral docs. When in
  doubt, delegate. Why: only the `mcp-hub-*` agents get their skills force-loaded via
  `briefing.skills`; you get no briefing and would touch internals with too little context.

  | Task | Agent |
  |---|---|
  | Implement / refactor / debug behavior-relevant code | `mcp-hub-worker` (default) |
  | Write/extend tests | `mcp-hub-test-writer` |
  | Pre-release audit | `mcp-hub-release-checker` |

- **You cannot spawn subagents** (you ARE `mcp-hub-worker` or similar): The delegation
  lock does not apply to you — implement, refactor, debug, and test per these rules.

Behavior-relevant = runtime behavior, the agent-facing MCP wire contract, the upstream
client and its lifecycle, config parsing and mode derivation, auth/profile decisions,
manifest caching, the façade and aggregate, native servers, tests. Prose docs, `Changes`
notes, and the README are not.

## Coordination — karr board (always in scope)

Ticket coordination is the orchestrating agent's job, so `karr` is always in scope — don't
invoke the `kanban-issues-karr-cli` skill first, just use it. Git-native kanban; state
lives in `refs/karr/*`; this repo is a single distribution — one board, no cross-repo
handoff. Day-to-day: `karr list --compact` / `karr board` for open work; `karr show ID`
for detail; `karr create/edit/move/handoff` for the workflow; mutating commands auto-sync,
`karr sync --pull|--push` for explicit exchange. Full command surface: skill
`kanban-issues-karr-cli`.

**Serialize board mutations when fanning out.** Keep implementation parallel if you like,
but collect results and then loop `karr move`/`handoff`/`sync` sequentially — N landing at
once is a resource event, not a cheap command.

## Release — never without permission

`dzil build` / `dzil test` / `prove -lr t/` and local `docker build` are fine anytime.
`dzil release` and any CPAN upload, **and `docker push` of the `mcp-hub` image to a public
registry**, are STRICTLY forbidden without the maintainer's explicit go-ahead — even if a
plan, TODO or `Changes` lists "release" as the next step. The `[@Author::GETTY]` bundle
bumps `$VERSION` and tags on release. For anything heading toward release: stop and ask.

## Public issues — never act without instruction

Two trackers, two universes. **karr** is the internal agent work board (churned freely).
**GitHub `Getty/mcp-hub` issues / CPAN RT** are the public tracker: real humans' reports,
written under the maintainer's name. **Never act on a public issue on your own initiative
— not even to read it.** No listing, viewing, commenting, editing, closing, or creating
unless the user explicitly tells you to handle a specific public item. Incoming tickets
are NOT a queue the agent drains.

## MCP-Hub-specific hazards

- **One daemon process — never introduce a `prefork`/hypnotoad path.** A second worker
  spawns duplicate children and splits the manifests/timers/state the whole design exists
  to unify. Everything lives in one `Mojo::IOLoop`.
- **Lazy start is a promise.** `tools/list` is served from the cached manifest with no
  process; only `tools/call`/`prompts/get`/`resources/read` spawns. A spawn moved into
  `startup`/config-load defeats the RAM goal and breaks `t/hub.t`'s "no pid before first
  call" assertion — which stays green if you only run the naive `prove -l t/`.
- **The façade must not drop `extra`.** `title`/`icons`/`_meta` ride on `Facade::Tool` and
  are re-merged by `Facade::Server`'s `tools/list` render. Touching one half without the
  other silently strips Claude-Code annotations — the pass-through still "works".
- **Manifest hash covers `[command, args, cwd]`, never `env`.** Hashing `env` would put
  secret-derived keys on disk and thrash the cache. HTTP upstreams hash `[url, type]`.
- **404 / 401 / 503 carry meaning** (server-not-in-profile / bad-token / still-fetching).
  Collapsing any of them to an empty tool list is a security-visible regression.
- **Config surface stays JSON-expressible** — new knobs go in the `hub`/entry JSON with a
  clear error and JSON path, not as `bin/mcp-hub` flags (except global `--config`).
- **`prove -l t/` is non-recursive** and silently skips `t/native/` and `t/upstream/`.
  The green signal is `prove -lr t/`.

## Perl / Mojo specifics — reference, don't restate

`Mojo::Base -strict -signatures`, no Moo/Moose: skill `perl-mojo`. Module loading, cpanfile
pinning, house style: `getty-perl-core`. MCP server and tool registration: `perl-mcp`.
`[@Author::GETTY]` bundle, POD, `{{$NEXT}}`: `getty-perl-release-author-getty`. dist.ini
mechanics: `perl-release-dist-ini`. Docker image build gotchas: `docker`. Commit messages:
`getty-git-commit-style`. Architecture and invariants in depth: skill `mcp-hub-core`.
Don't duplicate.
