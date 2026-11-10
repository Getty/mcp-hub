# MCP-Hub House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

One HTTP MCP server that embeds many, for a lot of MCP on little RAM. Read first: the whole
seam — the façade is one mechanism across three files (`Facade`, `Facade::Tool`,
`Facade::Server`); the lifecycle is `Upstream` plus its three subclasses. One karr board, no
cross-repo handoff.

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `mcp-hub-worker` (default) |
| Write/extend tests | `mcp-hub-test-writer` |
| Standalone binary: PAR::Packer build of `bin/mcp-hub` through the bundle's binary form — dist.ini's `binary*` keys, `scripts/*binary*`, `binaries.yml` | `mcp-hub-binary-worker` |
| Commits, `Changes`, card → done, pre-release audit | `mcp-hub-release-manager` |
| Read-only research, audit, gap analysis | `mcp-hub-worker` ("read-only, change nothing") |

Behavior-relevant = runtime behavior, the agent-facing MCP wire contract, the upstream client and
its lifecycle, config parsing and mode derivation, auth/profile decisions, manifest caching, the
façade and aggregate, native servers, tests. Prose docs, `Changes` notes, and the README are not.

## Release

Local `docker build` is fine anytime; any `docker push` of the `mcp-hub` image to a public
registry falls under the publish gate. The `[@Author::GETTY]` bundle bumps `$VERSION` and tags on
release.

## Deviations from the house rules

- **CPAN RT counts as a public tracker** alongside GitHub `Getty/mcp-hub` issues.

## Hazards — mechanism and background in skill `mcp-hub-core`

- **One process serves HTTP and owns all state — never a `prefork`/hypnotoad path.** Everything
  lives in one `Mojo::IOLoop`. Its child processes are exec'd upstreams or forked class workers
  (`Upstream::Fork`); a worker never runs the hub's loop, holds none of its fds or signal
  handlers, and ends with `_exit`.
- **Lazy start is a promise.** `tools/list` is served from the cached manifest with no process;
  only `tools/call`/`prompts/get`/`resources/read` spawns.
- **The façade must not drop `extra`.** `title`/`icons`/`_meta` ride on `Facade::Tool` and are
  re-merged by `Facade::Server`.
- **Manifest hash covers `[command, args, cwd]`, never `env`.** HTTP upstreams hash `[url, type]`.
- **404 / 401 / 503 carry meaning** (server-not-in-profile / bad-token / still-fetching, failed
  with its reason, or no tool list yet) — never collapse them to an empty tool list.
- **Config surface stays JSON-expressible** — new knobs go in the `hub`/entry JSON with a clear
  error and JSON path, not as `bin/mcp-hub` flags (except global `--config`).
- **`prove -l t/` is non-recursive** and silently skips `t/native/` and `t/upstream/` — the green
  signal is `prove -lr t/`.

## Perl / Mojo specifics — reference, don't restate

`Mojo::Base -strict -signatures`, no Moo/Moose: skill `perl-mojo`. Module loading, cpanfile
pinning, house style: `getty-perl-core`. MCP server and tool registration: `perl-mcp`.
`[@Author::GETTY]` bundle, POD, `{{$NEXT}}`: `getty-perl-release-author-getty`. dist.ini:
`perl-release-dist-ini`. Docker image: `docker`. Commit style: `getty-git-commit-style`.
Invariants in depth: `mcp-hub-core`.
